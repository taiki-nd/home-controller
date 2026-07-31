import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/spotify_models.dart';
import 'auth_service.dart';
import 'spotify_config.dart';

/// 待ち時間を人が読める形にする。Development Mode で枠を使い切ると Spotify は
/// Retry-After に数時間を返してくるので、「17870s」のままでは意味が取れない。
String formatDuration(Duration d) {
  if (d.inHours >= 1) {
    final minutes = d.inMinutes.remainder(60);
    return minutes == 0 ? '${d.inHours}時間' : '${d.inHours}時間$minutes分';
  }
  if (d.inMinutes >= 1) return '${d.inMinutes}分';
  return '${d.inSeconds}秒';
}

/// 呼び出し側が分岐したい失敗だけを型にする。それ以外は [SpotifyApiException]。
class SpotifyApiException implements Exception {
  SpotifyApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'SpotifyApiException($statusCode): $message';
}

/// 404 NO_ACTIVE_DEVICE。WiiM が寝ていて Connect デバイスとして消えている状態。
/// 設計メモ §9 の導線（公式アプリで一度起こす）を出すためのシグナル。
class NoActiveDeviceException extends SpotifyApiException {
  NoActiveDeviceException() : super('再生できるデバイスがありません', statusCode: 404);
}

/// 再認証が必要（refresh_token が死んでいる）。
class SpotifyAuthExpiredException extends SpotifyApiException {
  SpotifyAuthExpiredException() : super('再ログインが必要です', statusCode: 401);
}

/// Spotify Web API クライアント。
///
/// 中間サーバーは無く、全てここから直接叩く（設計メモ §13）。
class SpotifyApi {
  SpotifyApi(this._auth, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: SpotifyConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              // 4xx/5xx を例外にせず自前で分岐する。204 も正常系として扱いたい。
              validateStatus: (_) => true,
            ),
          );

  final AuthService _auth;
  final Dio _dio;

  /// 429 を食らったら [Retry-After] 秒だけ全リクエストを止める。
  /// ポーリングが回りっぱなしなので、個別リトライより全体を寝かせるほうが速く復帰する。
  DateTime? _rateLimitedUntil;

  /// 連続で 429 を食らったら待ち時間を伸ばす。成功したら 0 に戻す。
  int _consecutive429 = 0;

  /// Spotify のレート制限はローリング 30 秒ウィンドウで見られる。
  /// 「今どれだけ叩いているか」を出せないと調整しようがないので数えておく。
  final List<DateTime> _recentCalls = [];

  /// 直近 30 秒に投げたリクエスト数。
  int get callsInWindow {
    _trimRecentCalls();
    return _recentCalls.length;
  }

  void _trimRecentCalls() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _recentCalls.removeWhere((t) => t.isBefore(cutoff));
  }

  Duration? get rateLimitCooldown {
    final until = _rateLimitedUntil;
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  // ── 読み取り ───────────────────────────────────────────────────────────

  /// `GET /me/player`。204 は「停止中」として [PlaybackState.stopped] を返す。
  /// エラーにはしない（設計メモ §5）。
  ///
  /// market は付けない。`from_token` は `user-read-private` scope を要求する上
  /// （[searchTracks] 参照）、ここの失敗はポーリング側で握り潰されるので
  /// 黙って空のプレイヤーになる。user token なら省略で国が解決される。
  Future<PlaybackState> playbackState() async {
    final response = await _send('GET', '/me/player');
    if (response.statusCode == 204 || response.data == null) {
      return PlaybackState.stopped;
    }
    return PlaybackState.fromJson(_asMap(response.data));
  }

  /// `GET /me/player/queue`。返ってきた順がそのまま再生順（設計メモ §4）。
  Future<QueueSnapshot> queue() async {
    final response = await _send('GET', '/me/player/queue');
    if (response.statusCode == 204 || response.data == null) {
      return QueueSnapshot.empty;
    }
    return QueueSnapshot.fromJson(_asMap(response.data));
  }

  Future<List<SpotifyDevice>> devices() async {
    final response = await _send('GET', '/me/player/devices');
    final list = _asMap(response.data)['devices'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SpotifyDevice.fromJson)
        .whereType<SpotifyDevice>()
        .toList();
  }

  /// Development Mode では limit 上限 10、既定 5（設計メモ §6）。ページングが前提。
  ///
  /// **`market=from_token` を付けてはいけない。** この値は Spotify 側で
  /// `user-read-private` scope を要求するため、付けると 403
  /// `Insufficient client scope` になり検索が丸ごと失敗する。
  /// user token で叩いている限り market を省略すればユーザーの国が使われる。
  Future<SearchPage> searchTracks(String query, {int offset = 0}) async {
    if (query.trim().isEmpty) return SearchPage.empty;
    final response = await _send(
      'GET',
      '/search',
      query: {'q': query, 'type': 'track', 'limit': 10, 'offset': offset},
    );
    return SearchPage.fromJson(_asMap(response.data));
  }

  Future<List<PlaylistSummary>> playlists({int limit = 50}) async {
    final response = await _send('GET', '/me/playlists', query: {'limit': limit});
    final items = _asMap(response.data)['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(PlaylistSummary.fromJson)
        .whereType<PlaylistSummary>()
        .toList();
  }

  // ── 書き込み ───────────────────────────────────────────────────────────

  /// プレイリストを base として再生する。
  Future<void> playContext(String contextUri, {String? deviceId}) {
    return _send(
      'PUT',
      '/me/player/play',
      query: deviceId == null ? null : {'device_id': deviceId},
      body: {'context_uri': contextUri},
    );
  }

  /// 「今すぐ再生」。1 コールで確実にその曲が鳴る代わりに、
  /// **既存のキューと context は消える**（設計メモ §5・仕様として許容）。
  Future<void> playTrackNow(String trackUri, {String? deviceId}) {
    return _send(
      'PUT',
      '/me/player/play',
      query: deviceId == null ? null : {'device_id': deviceId},
      body: {
        'uris': [trackUri],
      },
    );
  }

  Future<void> resume({String? deviceId}) {
    return _send(
      'PUT',
      '/me/player/play',
      query: deviceId == null ? null : {'device_id': deviceId},
    );
  }

  Future<void> pause() => _send('PUT', '/me/player/pause');

  Future<void> next() => _send('POST', '/me/player/next');

  Future<void> previous() => _send('POST', '/me/player/previous');

  /// 「次に再生へ追加」。1 コールのみ。挿入順（FIFO）で鳴る。
  Future<void> addToQueue(String trackUri, {String? deviceId}) {
    return _send(
      'POST',
      '/me/player/queue',
      query: {
        'uri': trackUri,
        'device_id': ?deviceId,
      },
    );
  }

  Future<void> setShuffle(bool on, {String? deviceId}) {
    return _send(
      'PUT',
      '/me/player/shuffle',
      query: {
        'state': on,
        'device_id': ?deviceId,
      },
    );
  }

  /// WiiM へ再生を移す。`play: false` だと転送だけして再生状態は維持する。
  Future<void> transfer(String deviceId, {bool play = true}) {
    return _send(
      'PUT',
      '/me/player',
      body: {
        'device_ids': [deviceId],
        'play': play,
      },
    );
  }

  // ── 共通処理 ───────────────────────────────────────────────────────────

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool isRetry = false,
  }) async {
    final cooldown = rateLimitCooldown;
    if (cooldown != null) {
      throw SpotifyApiException(
        'Spotify のレート制限中（あと${formatDuration(cooldown)}）',
        statusCode: 429,
      );
    }

    final token = await _auth.accessToken();
    if (token == null) throw SpotifyAuthExpiredException();

    _trimRecentCalls();
    _recentCalls.add(DateTime.now());

    late final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(
          method: method,
          headers: {'Authorization': 'Bearer $token'},
          contentType: body == null ? null : Headers.jsonContentType,
        ),
      );
    } on DioException catch (e) {
      throw SpotifyApiException('通信に失敗しました: ${e.message ?? e.type.name}');
    }

    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      _consecutive429 = 0;
      return response;
    }

    switch (status) {
      case 401:
        // トークン期限切れ。1 回だけ強制リフレッシュして同じ要求をやり直す。
        if (isRetry) throw SpotifyAuthExpiredException();
        final refreshed = await _auth.accessToken(forceRefresh: true);
        if (refreshed == null) throw SpotifyAuthExpiredException();
        return _send(method, path, query: query, body: body, isRetry: true);

      case 403:
        throw SpotifyApiException(
          _errorMessage(response) ??
              'この操作は許可されていません（Premium アカウントが必要です）',
          statusCode: 403,
        );

      case 404:
        // Player 系の 404 は基本的に NO_ACTIVE_DEVICE。
        throw NoActiveDeviceException();

      case 429:
        _consecutive429++;
        // Retry-After は秒。Spotify が指定してきたらそれが正。
        // ヘッダが無いこともあるので、その場合だけ 5s から倍々で伸ばす（上限 60s）。
        final header = response.headers.value('retry-after');
        final fallback = (5 * (1 << (_consecutive429 - 1))).clamp(5, 60);
        final seconds = int.tryParse(header ?? '') ?? fallback;
        _rateLimitedUntil = DateTime.now().add(Duration(seconds: seconds));
        debugPrint(
          'Spotify 429 on $method $path — wait ${seconds}s '
          '(直近30秒に $callsInWindow 回 / 連続 $_consecutive429 回目)',
        );
        throw SpotifyApiException(
          'Spotify のレート制限に掛かりました'
          '（あと${formatDuration(Duration(seconds: seconds))}）',
          statusCode: 429,
        );

      default:
        throw SpotifyApiException(
          _errorMessage(response) ?? 'Spotify がエラーを返しました ($status)',
          statusCode: status,
        );
    }
  }

  String? _errorMessage(Response<dynamic> response) {
    final data = response.data;
    if (data is Map && data['error'] is Map) {
      final message = (data['error'] as Map)['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return null;
  }

  Map<String, dynamic> _asMap(dynamic data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};
}
