import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Music Assistant サーバーへの接続先と認証。
///
/// トークンは HA の長期アクセストークンと同じ性質の secret（MA の全操作が
/// 通る）なので、ビルドには埋めず端末の Keychain にだけ置く
/// （`docs/music-assistant-integration.md` §3）。
@immutable
class MaConnection {
  const MaConnection({required this.baseUrl, required this.token});

  final Uri baseUrl;

  /// MA 2.8 未満のサーバーには認証が無い。**空文字を許す。**
  /// 空のまま繋いだ場合は `auth` を送らない（§2）。
  final String token;

  /// `http://…:8095` → `ws://…:8095/ws`。
  ///
  /// `replace(query: '')` だと空のクエリが残って末尾に `?` が付くので、
  /// 組み直す。
  Uri get websocketUrl => Uri(
    scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
    path: '/ws',
  );

  /// 入力値を [Uri] に直す。
  ///
  /// 既定ポートが 8095 であること以外は [HaConnection.parseBaseUrl] と同じ判断。
  /// scheme 無しや末尾スラッシュを貼られても通す。
  static Uri? parseBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    // ポート未指定なら MA の既定 8095。https のときは触らない
    // （リバースプロキシ越しの 443 を書き換えてしまうため）。
    final port = uri.hasPort
        ? uri.port
        : (uri.scheme == 'http' ? 8095 : uri.port);
    return Uri(scheme: uri.scheme, host: uri.host, port: port, path: '');
  }

  @override
  bool operator ==(Object other) =>
      other is MaConnection &&
      other.baseUrl == baseUrl &&
      other.token == token;

  @override
  int get hashCode => Object.hash(baseUrl, token);
}

/// 接続情報の保管。トークンは Keychain / KeyStore に置く。
class MaCredentials {
  MaCredentials({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const _kBaseUrl = 'ma_base_url';
  static const _kToken = 'ma_access_token';

  final FlutterSecureStorage _storage;

  Future<MaConnection?> load() async {
    try {
      final url = await _storage.read(key: _kBaseUrl);
      if (url == null) return null;
      final base = Uri.tryParse(url);
      if (base == null || base.host.isEmpty) return null;
      // トークンは空でも接続できる（認証なしの古いサーバー）ので、
      // 無い＝未設定とは扱わない。アドレスの有無だけで判断する。
      return MaConnection(
        baseUrl: base,
        token: await _storage.read(key: _kToken) ?? '',
      );
    } catch (e) {
      // Keychain が読めない場合。未設定として扱えば設定画面に戻るだけで済む。
      debugPrint('MaCredentials.load failed: $e');
      return null;
    }
  }

  Future<void> save(MaConnection connection) async {
    await _storage.write(key: _kBaseUrl, value: connection.baseUrl.toString());
    await _storage.write(key: _kToken, value: connection.token);
  }

  Future<void> clear() async {
    await _storage.delete(key: _kBaseUrl);
    await _storage.delete(key: _kToken);
  }
}
