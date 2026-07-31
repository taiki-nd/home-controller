import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'spotify_config.dart';

/// サインインのどこで止まったか。タイムアウト時の文言を出し分けるためだけに使う。
enum _SignInStage { authorize, persist }

/// リフレッシュがネットワーク都合などで失敗した（refresh_token は生きている）。
///
/// 圏外や Wi-Fi 切り替え中でも token エンドポイントは当然失敗する。これを
/// 「トークンが死んだ」と扱うと、通信が戻っただけで済む場面で再ログインを
/// 強いることになるので、ここだけ型を分けてサインアウトさせない。
class AuthRefreshFailedException implements Exception {
  AuthRefreshFailedException(this.message);

  final String message;

  @override
  String toString() => 'AuthRefreshFailedException: $message';
}

/// Authorization Code + PKCE でのログインとトークン保持。
///
/// サーバーは無い（設計メモ §13）。PKCE なので client secret も無い。
class AuthService extends ChangeNotifier {
  AuthService({FlutterSecureStorage? storage, FlutterAppAuth? appAuth})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          ),
      _appAuth = appAuth ?? const FlutterAppAuth();

  static const _kRefreshToken = 'spotify_refresh_token';
  static const _kAccessToken = 'spotify_access_token';
  static const _kExpiresAt = 'spotify_access_token_expires_at';

  static const _serviceConfiguration = AuthorizationServiceConfiguration(
    authorizationEndpoint: SpotifyConfig.authorizationEndpoint,
    tokenEndpoint: SpotifyConfig.tokenEndpoint,
  );

  /// 期限ぎりぎりのトークンで API を叩いて 401 を食わないよう、早めに更新する。
  static const _expiryMargin = Duration(seconds: 60);

  /// ブラウザ側の操作時間を含むので長め。ここを無制限にすると、コールバックが
  /// 戻ってこなかったときにログイン画面が無限ローディングのまま固まる。
  static const _authorizeTimeout = Duration(minutes: 5);

  /// Keychain 書き込みは本来一瞬で終わる。返ってこない＝異常。
  static const _storageTimeout = Duration(seconds: 20);

  final FlutterSecureStorage _storage;
  final FlutterAppAuth _appAuth;

  String? _accessToken;
  DateTime? _expiresAt;
  String? _refreshToken;

  bool _restored = false;
  bool _busy = false;
  String? _error;

  /// 同時に複数の API 呼び出しが 401 を踏んでもリフレッシュは 1 回で済ませる。
  Future<String?>? _inflightRefresh;

  bool get isRestored => _restored;
  bool get isSignedIn => _refreshToken != null;
  bool get isBusy => _busy;
  String? get error => _error;

  /// 起動時に一度だけ呼ぶ。保存済みトークンを読み戻す。
  Future<void> restore() async {
    if (_restored) return;
    try {
      _refreshToken = await _storage.read(key: _kRefreshToken);
      _accessToken = await _storage.read(key: _kAccessToken);
      final raw = await _storage.read(key: _kExpiresAt);
      _expiresAt = raw == null ? null : DateTime.tryParse(raw);
    } catch (e) {
      // Keychain / KeyStore が壊れている場合。読めないなら未ログイン扱いで良い。
      debugPrint('AuthService.restore failed: $e');
      _refreshToken = null;
      _accessToken = null;
      _expiresAt = null;
    }
    _restored = true;
    notifyListeners();
  }

  Future<bool> signIn() async {
    if (!SpotifyConfig.isConfigured) {
      _error = 'SPOTIFY_CLIENT_ID が設定されていません';
      notifyListeners();
      return false;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    // 固まったときにどこで止まったかを言えるようにしておく。
    var stage = _SignInStage.authorize;
    try {
      final result = await _appAuth
          .authorizeAndExchangeCode(
            AuthorizationTokenRequest(
              SpotifyConfig.clientId,
              SpotifyConfig.redirectUri,
              serviceConfiguration: _serviceConfiguration,
              scopes: SpotifyConfig.scopes,
              // Spotify は既に認可済みでも同意画面を出せる。アカウントを
              // 切り替えたいときのために毎回選ばせる必要は無いので既定のまま。
            ),
          )
          .timeout(_authorizeTimeout);
      stage = _SignInStage.persist;
      await _persist(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        expiresAt: result.accessTokenExpirationDateTime,
      ).timeout(_storageTimeout);
      return isSignedIn;
    } on TimeoutException {
      debugPrint('AuthService.signIn: $stage で応答なし');
      _error = _describeTimeout(stage);
      return false;
    } on FlutterAppAuthUserCancelledException {
      // ユーザーがブラウザを閉じただけ。エラー表示はしない。
      return false;
    } catch (e) {
      debugPrint('AuthService.signIn: $stage で失敗: $e');
      _error = _describe(e);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
    await _storage.delete(key: _kExpiresAt);
    notifyListeners();
  }

  /// 有効な access token を返す。必要なら黙ってリフレッシュする。
  ///
  /// null＝refresh_token が拒否された（再ログインが要る）。
  /// 通信都合で更新できなかっただけなら [AuthRefreshFailedException] を投げる。
  Future<String?> accessToken({bool forceRefresh = false}) async {
    if (!_restored) await restore();
    if (!forceRefresh && _accessToken != null && _expiresAt != null) {
      if (DateTime.now().isBefore(_expiresAt!.subtract(_expiryMargin))) {
        return _accessToken;
      }
    }
    return _inflightRefresh ??= _refresh().whenComplete(() {
      _inflightRefresh = null;
    });
  }

  Future<String?> _refresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) return null;
    try {
      final result = await _appAuth.token(
        TokenRequest(
          SpotifyConfig.clientId,
          SpotifyConfig.redirectUri,
          serviceConfiguration: _serviceConfiguration,
          refreshToken: refreshToken,
          grantType: GrantType.refreshToken,
        ),
      );
      await _persist(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        expiresAt: result.accessTokenExpirationDateTime,
      );
      return _accessToken;
    } catch (e) {
      debugPrint('AuthService refresh failed: $e');
      if (_isTokenRejected(e)) {
        // refresh_token が無効化された（別端末でのローテーション、認可取り消し等）。
        // 保持していても意味がないので消して再ログインに倒す。
        await signOut();
        return null;
      }
      // それ以外（圏外・DNS 失敗・Spotify 側の 5xx 等）はトークンを残す。
      throw AuthRefreshFailedException('Spotify に接続できませんでした');
    }
  }

  /// 認可サーバーが grant そのものを拒否したか。
  ///
  /// ここが true のときだけトークンを捨てる。判別できない失敗は通信断と同じ
  /// 扱いにして残す（消すのは片道で、間違えると再ログインを強いるため）。
  static bool _isTokenRejected(Object e) {
    if (e is! FlutterAppAuthPlatformException) return false;
    return switch (e.platformErrorDetails.error) {
      FlutterAppAuthOAuthError.invalidGrant ||
      FlutterAppAuthOAuthError.invalidClient ||
      FlutterAppAuthOAuthError.unauthorizedClient ||
      FlutterAppAuthOAuthError.invalidScope => true,
      _ => false,
    };
  }

  /// **PKCE ではリフレッシュのたびに新しい refresh_token が返る（ローテーション）。**
  /// 返ってきたほうを必ず上書きしないと、次のリフレッシュで確実に失敗する。
  /// 設計メモ §13「踏みやすい罠」がこれ。
  Future<void> _persist({
    required String? accessToken,
    required String? refreshToken,
    required DateTime? expiresAt,
  }) async {
    if (accessToken != null) {
      _accessToken = accessToken;
      await _storage.write(key: _kAccessToken, value: accessToken);
    }
    if (refreshToken != null) {
      _refreshToken = refreshToken;
      await _storage.write(key: _kRefreshToken, value: refreshToken);
    }
    if (expiresAt != null) {
      _expiresAt = expiresAt;
      await _storage.write(
        key: _kExpiresAt,
        value: expiresAt.toIso8601String(),
      );
    }
    notifyListeners();
  }

  String _describeTimeout(_SignInStage stage) => switch (stage) {
    // ブラウザは閉じたのに結果が返らない＝コールバック URL が
    // アプリに届いていないか、トークン交換が返ってきていない。
    _SignInStage.authorize =>
      'Spotify から結果が返ってきませんでした。'
          'Dashboard の Redirect URIs と Info.plist の CFBundleURLSchemes が '
          '${SpotifyConfig.redirectUri} と一致しているか確認してください。',
    _SignInStage.persist =>
      'トークンの保存が終わりませんでした（Keychain 応答なし）。'
          'アプリを再起動してもう一度お試しください。',
  };

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('Insecure redirect URI')) {
      // 設計メモ §13 の詰まりどころ。原因を名指しで出す。
      return 'リダイレクト URI が拒否されました。Dashboard に '
          '${SpotifyConfig.redirectUri} を登録するか、Universal Links に切り替えてください。';
    }
    return 'サインインに失敗しました: $text';
  }
}
