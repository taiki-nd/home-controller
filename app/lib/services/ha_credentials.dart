import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// HA への接続先と認証。
///
/// **長期アクセストークンは Spotify の Client ID と性質が違う。**
/// Client ID は PKCE 前提の公開値なのでビルドに埋めてよかったが、こちらは
/// HA の全権限を持つ本物の secret なので、埋め込まず端末の Keychain にだけ置く
/// （`docs/home-assistant-integration.md` §7）。
@immutable
class HaConnection {
  const HaConnection({required this.baseUrl, required this.token});

  final Uri baseUrl;
  final String token;

  /// `http://…:8123` → `ws://…:8123/api/websocket`。
  Uri get websocketUrl => baseUrl.replace(
    scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
    path: '/api/websocket',
    query: '',
  );

  /// 入力値を [Uri] に直す。
  ///
  /// scheme 無し（`192.168.1.10:8123`）や末尾スラッシュ、`/lovelace` のような
  /// パス付きを貼られても通るようにする。**ここで弾くと設定画面で詰まる**ので、
  /// 直せるものは直して受ける。
  static Uri? parseBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    // ポート未指定なら HA の既定 8123。https のときは触らない
    // （リバースプロキシ越しの 443 を 8123 に書き換えてしまうため）。
    final port = uri.hasPort
        ? uri.port
        : (uri.scheme == 'http' ? 8123 : uri.port);
    return Uri(scheme: uri.scheme, host: uri.host, port: port, path: '');
  }

  @override
  bool operator ==(Object other) =>
      other is HaConnection &&
      other.baseUrl == baseUrl &&
      other.token == token;

  @override
  int get hashCode => Object.hash(baseUrl, token);
}

/// 接続情報の保管。トークンは Keychain / KeyStore に置く。
class HaCredentials {
  HaCredentials({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const _kBaseUrl = 'ha_base_url';
  static const _kToken = 'ha_access_token';

  final FlutterSecureStorage _storage;

  Future<HaConnection?> load() async {
    try {
      final url = await _storage.read(key: _kBaseUrl);
      final token = await _storage.read(key: _kToken);
      if (url == null || token == null || token.isEmpty) return null;
      final base = Uri.tryParse(url);
      if (base == null || base.host.isEmpty) return null;
      return HaConnection(baseUrl: base, token: token);
    } catch (e) {
      // Keychain が読めない場合。未設定として扱えば設定画面に戻るだけで済む。
      debugPrint('HaCredentials.load failed: $e');
      return null;
    }
  }

  Future<void> save(HaConnection connection) async {
    await _storage.write(key: _kBaseUrl, value: connection.baseUrl.toString());
    await _storage.write(key: _kToken, value: connection.token);
  }

  Future<void> clear() async {
    await _storage.delete(key: _kBaseUrl);
    await _storage.delete(key: _kToken);
  }
}
