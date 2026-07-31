import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/auth_service.dart';

/// 圏外での起動でトークンを捨ててしまうと再ログインを強いることになる。
/// 「捨てるのは認可サーバーが拒否したときだけ」をここで固定する。
class FakeStorage implements FlutterSecureStorage {
  FakeStorage(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// token() が必ず [error] で失敗する AppAuth。
class FailingAppAuth implements FlutterAppAuth {
  FailingAppAuth(this.error);

  /// 認可サーバーから返った OAuth のエラーコード。通信断なら null。
  final String? error;

  @override
  Future<TokenResponse> token(TokenRequest request) async {
    throw FlutterAppAuthPlatformException(
      code: 'token_failed',
      platformErrorDetails: FlutterAppAuthPlatformErrorDetails(error: error),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthService buildSignedIn(FlutterAppAuth appAuth, Map<String, String> values) {
  return AuthService(storage: FakeStorage(values), appAuth: appAuth);
}

void main() {
  Map<String, String> storedTokens() => {
    'spotify_refresh_token': 'rt-1',
    'spotify_access_token': 'at-1',
    // 期限切れにしておき、accessToken() が必ずリフレッシュへ入るようにする。
    'spotify_access_token_expires_at': DateTime(2020).toIso8601String(),
  };

  test('通信都合の失敗では refresh_token を捨てない', () async {
    final values = storedTokens();
    final auth = buildSignedIn(FailingAppAuth(null), values);

    await expectLater(
      auth.accessToken(),
      throwsA(isA<AuthRefreshFailedException>()),
    );
    expect(auth.isSignedIn, isTrue);
    expect(values['spotify_refresh_token'], 'rt-1');
  });

  test('invalid_grant ならサインアウトする', () async {
    final values = storedTokens();
    final auth = buildSignedIn(
      FailingAppAuth(FlutterAppAuthOAuthError.invalidGrant),
      values,
    );

    expect(await auth.accessToken(), isNull);
    expect(auth.isSignedIn, isFalse);
    expect(values.containsKey('spotify_refresh_token'), isFalse);
  });
}
