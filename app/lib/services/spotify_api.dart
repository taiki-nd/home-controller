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

/// 403 `Insufficient client scope`。トークン自体は生きているが、認可された
/// scope にそのエンドポイントぶんが入っていない。
///
/// [SpotifyConfig.scopes] に追加したあと再連携していない既存ユーザーが必ず
/// ここを踏む。普通の 403（Premium が要る等）と混ぜると「よく分からない
/// エラー」になるので型を分ける。手前で防ぐのは
/// [AuthService.needsReauthorization] の役目で、こちらは取りこぼしの受け皿。
class SpotifyScopeException extends SpotifyApiException {
  SpotifyScopeException()
    : super('Spotify との再連携が必要です（☰ → SPOTIFY と再連携）', statusCode: 403);
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

  /// 認可済みトークンに足りない scope。403 の切り分けと、書き込みを試す前の
  /// 足切りに使う（[SpotifyConfig.scopes] との差）。
  Set<String> get missingScopes => _auth.missingScopes;

  /// プレイリストの中身を書き換えるのに要る scope。公開・非公開で別。
  static const _playlistWriteScopes = {
    'playlist-modify-public',
    'playlist-modify-private',
  };

  static bool _isPlaylistWrite(String method, String path) =>
      method != 'GET' && path.startsWith('/playlists/');

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

  /// `GET /artists/{id}/albums`。新譜（MusicBrainz 由来）の行を鳴らすとき、
  /// **そのアーティストの棚の中だけで突き合わせる**ために使う（設計メモ §14）。
  ///
  /// 全文検索（`/search?type=album`）は使わない。関連度順で返るだけなので、
  /// クエリの片側しか合っていない別アーティストの盤を掴む。ここなら候補が
  /// そのアーティストの盤に限られるので、その事故が原理的に起きない。
  ///
  /// [searchTracks] と同じく **`market=from_token` は付けない**（403 になる）。
  /// 付けないぶん同じアルバムが国別に重複して返るが、呼び出し側は最初に
  /// 当たったものを使うので困らない。
  Future<List<SpotifyAlbumMatch>> artistAlbums(
    String artistId, {
    int limit = 50,
  }) async {
    if (artistId.isEmpty) return const [];
    final response = await _send(
      'GET',
      '/artists/$artistId/albums',
      // コンピレーションや客演（appears_on）は新譜として出していないので引かない。
      query: {'include_groups': 'album,single', 'limit': limit},
    );
    final items = _asMap(response.data)['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(SpotifyAlbumMatch.fromJson)
        .whereType<SpotifyAlbumMatch>()
        .toList();
  }

  /// `GET /albums/{id}`。MusicBrainz が持っている配信リンクから拾った ID を
  /// 実体にするために使う。消えた ID なら null（404 は失敗にしない）。
  Future<SpotifyAlbumMatch?> album(String albumId) async {
    if (albumId.isEmpty) return null;
    try {
      final response = await _send('GET', '/albums/$albumId');
      return SpotifyAlbumMatch.fromJson(_asMap(response.data));
    } on SpotifyApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// `GET /me/following?type=artist` を全ページ舐める。要 `user-follow-read`。
  ///
  /// **戻り値の順序に意味を持たせてはいけない。** カーソル（`after` = 最後に
  /// 受け取ったアーティストID）の並び順は仕様に定義がなく、ページングの最中に
  /// フォローが増減すると取りこぼしや重複が起こり得る。呼び出し側は集合として
  /// 扱うこと（新譜の母集団を作るのが用途なので、それで困らない）。
  ///
  /// 差分だけを取る API は存在しない（`followed_at` も無い）。フォロー 200 人で
  /// 4 リクエスト程度なので、毎回全部取ってローカルで差分を出すほうが、
  /// `total` の増減を見るより確実（同数の入れ替えを取りこぼさない）。
  Future<List<FollowedArtist>> followedArtists() async {
    final artists = <FollowedArtist>[];
    String? after;
    // 万一 cursor が進まなくても無限ループにしない。50 件 × 40 ページ。
    for (var page = 0; page < 40; page++) {
      final response = await _send(
        'GET',
        '/me/following',
        query: {
          'type': 'artist',
          'limit': 50,
          'after': ?after,
        },
      );
      final block = _asMap(response.data)['artists'];
      if (block is! Map<String, dynamic>) break;
      final items = block['items'] as List<dynamic>? ?? const [];
      artists.addAll(
        items
            .whereType<Map<String, dynamic>>()
            .map(FollowedArtist.fromJson)
            .whereType<FollowedArtist>(),
      );
      if (block['next'] == null) return artists;
      final next =
          (block['cursors'] as Map<String, dynamic>?)?['after'] as String?;
      // next はあるのに cursor が無い / 進んでいないなら、これ以上は追えない。
      if (next == null || next == after) break;
      after = next;
    }
    // next を辿り切る前に抜けた（cursor が壊れている / ページ上限）。
    debugPrint('followedArtists: ページングを途中で打ち切り（${artists.length} 件）');
    return artists;
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

  /// `GET /me` の `id`。プレイリストを編集できるかの判定にだけ使う。
  ///
  /// email / country は scope が要るが、`id` は user token だけで返ってくる。
  /// それでも失敗したら呼ぶ側は null 扱いで続ける（[PlaylistSummary.isEditableBy]）。
  Future<String?> currentUserId() async {
    final response = await _send('GET', '/me');
    return _asMap(response.data)['id'] as String?;
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

  /// プレイリストの末尾に 1 曲足す。要 `playlist-modify-public` /
  /// `playlist-modify-private`。
  ///
  /// **パスは `/items`。`/tracks` は 2026 年 2 月の移行で廃止された**
  /// （Web API Changelog - February 2026）。古いパスを叩くと、権限が揃っていても
  /// 素の `403 Forbidden` が返る。文面に理由が出ないので、当たると原因を追うのに
  /// 時間が掛かる。
  ///
  /// **重複はチェックされない。** 同じ曲を 2 回足せば 2 行入る。手前で
  /// 「もう入っているか」を知る API は無いので、呼ぶ側で押させ過ぎない。
  Future<void> addTrackToPlaylist(String playlistId, String trackUri) {
    return _send(
      'POST',
      '/playlists/$playlistId/items',
      body: {
        'uris': [trackUri],
      },
    );
  }

  /// プレイリストからその曲を消す。位置を指定しないので、**同じ曲が複数入って
  /// いれば全部消える**（Spotify の仕様）。
  ///
  /// パスが `/items` になったのと同時に、**body の鍵も `tracks` → `items`** に
  /// 変わっている（[addTrackToPlaylist] のコメント参照）。
  Future<void> removeTrackFromPlaylist(String playlistId, String trackUri) {
    return _send(
      'DELETE',
      '/playlists/$playlistId/items',
      body: {
        'items': [
          {'uri': trackUri},
        ],
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

    final String? token;
    try {
      token = await _auth.accessToken();
    } on AuthRefreshFailedException catch (e) {
      // トークンは生きている。通信が戻れば次の呼び出しで通る。
      throw SpotifyApiException(e.message);
    }
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
        final String? refreshed;
        try {
          refreshed = await _auth.accessToken(forceRefresh: true);
        } on AuthRefreshFailedException catch (e) {
          throw SpotifyApiException(e.message);
        }
        if (refreshed == null) throw SpotifyAuthExpiredException();
        return _send(method, path, query: query, body: body, isRetry: true);

      case 403:
        final message = _errorMessage(response);
        debugPrint(
          'Spotify 403 on $method $path — message=$message / '
          '足りない scope=${_auth.missingScopes}',
        );
        // 「権限が足りない」と「Premium が要る」は同じ 403 で返るので、
        // 文面でしか切り分けられない。
        if (message != null &&
            message.toLowerCase().contains('insufficient client scope')) {
          throw SpotifyScopeException();
        }
        // ただし **`/playlists/*` の書き込みは素の "Forbidden" しか返さない。**
        // 文面が使えないので、控えている scope で切り分ける。
        if (_isPlaylistWrite(method, path)) {
          if (_auth.missingScopes.any(_playlistWriteScopes.contains)) {
            throw SpotifyScopeException();
          }
          if (!_auth.scopesVerified) {
            // 控えは「要求どおり出たはず」という仮定だった。**403 のほうが実測**
            // なので控えを落とし、再連携の導線（バナー・☰）を出させる。
            unawaited(_auth.invalidateScopeRecord(_playlistWriteScopes));
            throw SpotifyScopeException();
          }
          // Spotify が「書き込み権限あり」と返したトークンで拒否された。
          // ここまで来たら scope の話ではないので、再連携を勧めてはいけない。
          // **非公開かどうかは関係ない**（非公開でも自分のリストなら書ける）。
          throw SpotifyApiException(
            'このプレイリストは編集できません。'
            'Spotify が作ったリスト（Discover Weekly・Daily Mix・Blend など）と'
            '他人のリストは、権限があっても書き換えられません。',
            statusCode: 403,
          );
        }
        throw SpotifyApiException(
          message ?? 'この操作は許可されていません（Premium アカウントが必要です）',
          statusCode: 403,
        );

      case 404:
        // Player 系の 404 は基本的に NO_ACTIVE_DEVICE。
        // それ以外（プレイリスト等）の 404 は「その id が無い」なので、
        // デバイス消失のオーバーレイを出してしまわないよう混ぜない。
        if (path.startsWith('/me/player')) throw NoActiveDeviceException();
        throw SpotifyApiException(
          _errorMessage(response) ?? '対象が見つかりませんでした',
          statusCode: 404,
        );

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
