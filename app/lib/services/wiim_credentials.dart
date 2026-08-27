import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// WiiM の在り処。
///
/// **SSDP では探さない**（`docs/qobuz-wiim-integration.md` §5）。
/// iOS でマルチキャストを使うには `com.apple.developer.networking.multicast`
/// が要り、Apple の申請と承認が必要になる。DHCP 予約で固定した IP を手で
/// 入れるほうが、個人利用では確実で速い。
@immutable
class WiimConnection {
  const WiimConnection({required this.host});

  /// `192.168.1.42` のようなホスト。scheme もパスも持たない。
  final String host;

  /// `https://<host>/httpapi.asp?command=<command>`。
  ///
  /// **自己署名証明書なので検証を切る必要がある**（`WiimApi` 参照）。
  /// Qobuz 用の HTTP クライアントとは必ず分ける。
  Uri commandUrl(String command) =>
      Uri.parse('https://$host/httpapi.asp?command=$command');

  /// 入力値からホストだけ取り出す。`http://192.168.1.42/` でも通す。
  static String? parseHost(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.contains('://')) {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) return null;
      text = uri.host;
    }
    // 末尾のスラッシュとポートは落とす（httpapi は 443 固定）。
    text = text.split('/').first.split(':').first;
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is WiimConnection && other.host == host;

  @override
  int get hashCode => host.hashCode;
}

/// WiiM の IP の保管。
///
/// 秘密ではないが、`shared_preferences` を足すためだけに依存を増やしたくない
/// ので Qobuz 側と同じ金庫に置く。
class WiimCredentials {
  WiimCredentials({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const _kHost = 'wiim_host';

  final FlutterSecureStorage _storage;

  Future<WiimConnection?> load() async {
    try {
      final host = await _storage.read(key: _kHost);
      if (host == null || host.isEmpty) return null;
      return WiimConnection(host: host);
    } catch (e) {
      debugPrint('WiimCredentials.load failed: $e');
      return null;
    }
  }

  Future<void> save(WiimConnection connection) =>
      _storage.write(key: _kHost, value: connection.host);

  Future<void> clear() => _storage.delete(key: _kHost);
}
