import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_config.dart';

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

/// token() が成功する AppAuth。返す scope を差し替えられる。
class _RefreshingAppAuth implements FlutterAppAuth {
  _RefreshingAppAuth({this.scopes});

  /// トークンに実際に付いた scope。null なら「返ってこなかった」。
  final List<String>? scopes;

  @override
  Future<TokenResponse> token(TokenRequest request) async => TokenResponse(
    'at-2',
    'rt-2',
    DateTime.now().add(const Duration(hours: 1)),
    null,
    'Bearer',
    scopes,
    null,
  );

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

  // 控えが実態より広いと「バナーは出ないのに 403」になる。Spotify は既に承認
  // 済みのアプリだと同意画面を飛ばし、古い scope のトークンを返すことがあるので、
  // 要求 scope をそのまま控えていると気づけない。
  group('scope の控えは実際に付いたものに合わせる', () {
    test('リフレッシュで狭い scope が返れば、再連携が必要だと分かる', () async {
      final values = storedTokens()
        // 全部持っているつもりで控えてある状態（前のバージョンの控え方）。
        ..['spotify_granted_scopes'] = SpotifyConfig.scopes.join(' ');
      final auth = buildSignedIn(
        // 実際のトークンにはプレイリストの書き込みが付いていない。
        _RefreshingAppAuth(
          scopes: SpotifyConfig.scopes
              .where((s) => !s.startsWith('playlist-modify'))
              .toList(),
        ),
        values,
      );

      expect(auth.needsReauthorization, isFalse, reason: '読み戻した時点では控えどおり');
      await auth.accessToken();

      expect(auth.missingScopes, {
        'playlist-modify-public',
        'playlist-modify-private',
      });
      expect(auth.needsReauthorization, isTrue);
      expect(
        values['spotify_granted_scopes'],
        isNot(contains('playlist-modify')),
      );
    });

    test('scope が返ってこなければ控えを消さない', () async {
      final values = storedTokens()
        ..['spotify_granted_scopes'] = SpotifyConfig.scopes.join(' ');
      final auth = buildSignedIn(_RefreshingAppAuth(), values);

      await auth.accessToken();

      expect(auth.missingScopes, isEmpty);
      expect(values['spotify_granted_scopes'], SpotifyConfig.scopes.join(' '));
    });
  });
}
