import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/wiim_models.dart';
import 'insecure_adapter.dart';
import 'wiim_credentials.dart';
import 'wiim_upnp.dart';

/// WiiM とのやり取りが失敗した。文言はそのまま画面に出す前提で作る。
class WiimException implements Exception {
  WiimException(this.message);

  final String message;

  @override
  String toString() => 'WiimException: $message';
}

/// 署名付き URL の載せ方。
///
/// **どちらが通るかは実機で確かめるしかない**（`docs/qobuz-wiim-integration.md`
/// §5.2）。Qobuz の URL は `?` と `&` を含むので、httpapi.asp のクエリ解析で
/// 途中まで切られる可能性がある。生で通る個体もあれば、percent-encode が要る
/// 個体もある——という報告が両方あるため、片方に賭けずに両方持つ。
enum WiimUrlEncoding {
  /// そのまま繋ぐ。多くの実装（python-linkplay 等）はこちら。
  raw,

  /// `&` を `%26` などに逃がす。特殊文字で切られる個体向け。
  percent;

  String apply(String url) =>
      this == WiimUrlEncoding.raw ? url : Uri.encodeComponent(url);
}

/// WiiM HTTP API のクライアント（`docs/qobuz-wiim-integration.md` §5）。
///
/// **Qobuz 用の [Dio] とは必ず分ける。** こちらは自己署名証明書を通すために
/// 検証を切っており、その設定を Qobuz 側に波及させてはいけない。
class WiimApi {
  WiimApi({WiimConnection? connection, Dio? dio, WiimUpnp? upnp})
    : _connection = connection,
      _upnp = upnp ?? WiimUpnp(connection: connection),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 8),
              // 応答は Content-Type が text/html のことがあるので、
              // dio に JSON と解釈させず自分で読む。
              responseType: ResponseType.plain,
            ),
          ) {
    if (dio == null) allowSelfSignedCertificates(_dio);
  }

  final Dio _dio;
  final WiimUpnp _upnp;

  /// 直近に通った載せ方を覚えておく口。
  ///
  /// 1 曲目で当たりが分かれば、以降は最初から通る形で送れる。
  /// **UPnP が通っている間はこれを使わない**（§5.2 の問題ごと消える）。
  WiimUrlEncoding urlEncoding = WiimUrlEncoding.raw;

  /// UPnP を最後に断られた時刻。通っている間は null。
  ///
  /// **諦めっぱなしにしない。** 曲送りのたびに 5 秒待たされるのは避けたい
  /// が、一度の取りこぼし（本体の再起動中・スリープ復帰直後・Wi-Fi の瞬断）
  /// で倒れたままだと、以降そのアプリ起動の間ずっと本体の画面が署名付き
  /// URL と既定のジャケットに戻る。[_upnpRetryAfter] 空けて試し直す。
  DateTime? _upnpDeniedAt;

  /// 断られてから試し直すまで。曲送り連打で 5 秒待ちが並ばない程度に置く。
  static const _upnpRetryAfter = Duration(minutes: 2);

  /// 直近の [play] が UPnP で通ったか。**画面に出すため**——黙って落とすと、
  /// 本体の表示だけ既定に戻った理由が誰にも分からない。
  bool get upnpDenied => _upnpDeniedAt != null;

  WiimConnection? _connection;

  /// 接続先。設定画面で入れ替わる。
  WiimConnection? get connection => _connection;

  set connection(WiimConnection? value) {
    _connection = value;
    _upnp.connection = value;
    _upnpDeniedAt = null;
  }

  bool get isConfigured => _connection != null;

  // ── 状態 ────────────────────────────────────────────────────────────

  Future<WiimStatus> status({DateTime? now}) async {
    final json = await _json('getPlayerStatus');
    return WiimStatus.fromJson(json, now: now);
  }

  Future<WiimDevice> device() async {
    final json = await _json('getStatusEx');
    return WiimDevice.fromJson(json);
  }

  // ── 再生 ────────────────────────────────────────────────────────────

  /// URL を投げて鳴らす。
  ///
  /// **URL は再生直前に取ったものを渡すこと**（Qobuz の署名は 24 時間で切れる）。
  ///
  /// [meta] があれば UPnP の `SetAVTransportURI` を先に試す。**HTTP API の
  /// `play:url` には曲名もジャケットも載せる口が無く**、その経路で送ると
  /// WiiM 本体のディスプレイに署名付き URL がそのまま出る（§5.5）。
  /// UPnP が断られたら黙って HTTP API に落とす——鳴ることの方が大事。
  Future<WiimPlayRoute> play(
    String url, {
    WiimTrackMetadata? meta,
    WiimUrlEncoding? encoding,
    DateTime? now,
  }) async {
    if (meta != null && _upnpReady(now: now)) {
      try {
        await _upnp.play(url, meta);
        _upnpDeniedAt = null;
        return WiimPlayRoute.upnp;
      } on WiimUpnpException catch (e) {
        debugPrint('WiimApi: UPnP を諦めて HTTP API に落とします（$e）');
        _upnpDeniedAt = now ?? DateTime.now();
      }
    }
    await _send('setPlayerCmd:play:${(encoding ?? urlEncoding).apply(url)}');
    return WiimPlayRoute.httpApi;
  }

  /// UPnP を試してよいか。断られた直後だけ避ける。
  bool _upnpReady({DateTime? now}) {
    final deniedAt = _upnpDeniedAt;
    if (deniedAt == null) return true;
    return (now ?? DateTime.now()).difference(deniedAt) >= _upnpRetryAfter;
  }

  Future<void> pause() => _send('setPlayerCmd:pause');
  Future<void> resume() => _send('setPlayerCmd:resume');
  Future<void> stop() => _send('setPlayerCmd:stop');

  /// 秒指定のシーク。**ミリ秒ではない**（`getPlayerStatus` の curpos とは単位が違う）。
  Future<void> seek(Duration position) =>
      _send('setPlayerCmd:seek:${position.inSeconds}');

  Future<void> setVolume(int level) =>
      _send('setPlayerCmd:vol:${level.clamp(0, 100)}');

  Future<void> setMute(bool muted) =>
      _send('setPlayerCmd:mute:${muted ? 1 : 0}');

  // ── 下回り ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _json(String command) async {
    final body = await _send(command);
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('WiimApi $command: JSON として読めませんでした');
    }
    throw WiimException('WiiM の応答を読めませんでした');
  }

  Future<String> _send(String command) async {
    final connection = _connection;
    if (connection == null) throw WiimException('WiiM の IP が設定されていません');
    try {
      // **`Uri.parse` した URL をそのまま渡す。** queryParameters 経由だと
      // dio がクエリを組み直してしまい、`play:<url>` に載せた署名付き URL の
      // エスケープが変わる。
      final response = await _dio.getUri<String>(
        connection.commandUrl(command),
      );
      final body = response.data ?? '';
      // 失敗しても 200 で "unknown command" を返す個体がある。
      if (body.toLowerCase().startsWith('unknown command')) {
        throw WiimException('WiiM がコマンドを受け付けませんでした');
      }
      return body;
    } on DioException catch (e) {
      debugPrint('WiimApi $command failed: ${e.type}');
      throw WiimException(
        // ローカルネットワーク権限が無いと、ここで無言のタイムアウトになる。
        // **iOS の Info.plist（NSLocalNetworkUsageDescription）を疑う**
        // 一番の手掛かりなので、文言に出しておく（§6）。
        'WiiM に接続できませんでした（IP とローカルネットワークの許可を確認）',
      );
    }
  }

  void close() {
    _dio.close(force: true);
    _upnp.close();
  }
}
