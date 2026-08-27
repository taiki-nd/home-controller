import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Qobuz を叩くための 2 つ組。
///
/// **ビルドに埋めない**（`docs/qobuz-wiim-integration.md` §6）。
/// 非公式の値で、失効したら差し替える必要がある。埋めてしまうと配り直しに
/// なるので、設定として端末に置く。
@immutable
class QobuzAppConfig {
  const QobuzAppConfig({required this.appId, required this.appSecret});

  /// Web プレイヤーの `app_id`。数字 9 桁。
  final String appId;

  /// `track/getFileUrl` の署名に使う秘密。bundle.js から取れる。
  final String appSecret;

  bool get isComplete => appId.isNotEmpty && appSecret.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is QobuzAppConfig &&
      other.appId == appId &&
      other.appSecret == appSecret;

  @override
  int get hashCode => Object.hash(appId, appSecret);

  @override
  String toString() => 'QobuzAppConfig(appId: $appId, appSecret: ****)';
}

/// ログイン済みの資格情報。
@immutable
class QobuzAccount {
  const QobuzAccount({
    required this.token,
    required this.userId,
    this.displayName,
    this.subscription,
  });

  /// `X-User-Auth-Token`。**ログ出力厳禁**（§6）。
  final String token;

  /// 自分のプレイリストかを判定するのに要る。
  final int userId;

  final String? displayName;
  final String? subscription;

  @override
  String toString() =>
      'QobuzAccount(userId: $userId, displayName: $displayName, token: ****)';
}

/// Qobuz 側の保管。**すべて Keychain / KeyStore に置く。**
///
/// app_id / app_secret は秘密ではないが、トークンと寿命を共にする
/// （どちらかが変われば繋ぎ直し）ので同じ場所にまとめる。
class QobuzCredentials {
  QobuzCredentials({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const _kAppId = 'qobuz_app_id';
  static const _kAppSecret = 'qobuz_app_secret';
  static const _kToken = 'qobuz_user_auth_token';
  static const _kUserId = 'qobuz_user_id';
  static const _kDisplayName = 'qobuz_display_name';
  static const _kSubscription = 'qobuz_subscription';

  final FlutterSecureStorage _storage;

  Future<QobuzAppConfig?> loadApp() async {
    try {
      final id = await _storage.read(key: _kAppId);
      final secret = await _storage.read(key: _kAppSecret);
      if (id == null || id.isEmpty) return null;
      return QobuzAppConfig(appId: id, appSecret: secret ?? '');
    } catch (e) {
      // Keychain が読めないだけなら未設定として扱う。設定画面に戻るだけで済む。
      debugPrint('QobuzCredentials.loadApp failed: $e');
      return null;
    }
  }

  Future<void> saveApp(QobuzAppConfig config) async {
    await _storage.write(key: _kAppId, value: config.appId);
    await _storage.write(key: _kAppSecret, value: config.appSecret);
  }

  Future<QobuzAccount?> loadAccount() async {
    try {
      final token = await _storage.read(key: _kToken);
      final userId = int.tryParse(await _storage.read(key: _kUserId) ?? '');
      if (token == null || token.isEmpty || userId == null) return null;
      return QobuzAccount(
        token: token,
        userId: userId,
        displayName: await _storage.read(key: _kDisplayName),
        subscription: await _storage.read(key: _kSubscription),
      );
    } catch (e) {
      debugPrint('QobuzCredentials.loadAccount failed: $e');
      return null;
    }
  }

  Future<void> saveAccount(QobuzAccount account) async {
    await _storage.write(key: _kToken, value: account.token);
    await _storage.write(key: _kUserId, value: '${account.userId}');
    await _storage.write(key: _kDisplayName, value: account.displayName ?? '');
    await _storage.write(
      key: _kSubscription,
      value: account.subscription ?? '',
    );
  }

  /// ログアウト。**app_id / app_secret は消さない。**
  /// 入れ直すのが面倒な値で、消す理由もアカウントとは別（失効したときだけ）。
  Future<void> clearAccount() async {
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kUserId);
    await _storage.delete(key: _kDisplayName);
    await _storage.delete(key: _kSubscription);
  }

  Future<void> clearAll() async {
    await clearAccount();
    await _storage.delete(key: _kAppId);
    await _storage.delete(key: _kAppSecret);
  }
}
