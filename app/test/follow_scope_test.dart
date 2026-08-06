import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/services/spotify_config.dart';

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

/// リクエストごとに応答を差し替えられる Dio アダプタ。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// リフレッシュに入らない、生きている access token を持った AuthService。
AuthService signedInAuth({Map<String, String>? extra}) => AuthService(
  storage: FakeStorage({
    'spotify_refresh_token': 'rt-1',
    'spotify_access_token': 'at-1',
    'spotify_access_token_expires_at': DateTime.now()
        .add(const Duration(hours: 1))
        .toIso8601String(),
    ...?extra,
  }),
);

SpotifyApi apiWith(FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(baseUrl: SpotifyConfig.apiBaseUrl, validateStatus: (_) => true),
  )..httpClientAdapter = adapter;
  return SpotifyApi(signedInAuth(), dio: dio);
}

Map<String, dynamic> _artist(String id) => {
  'id': id,
  'uri': 'spotify:artist:$id',
  'name': 'Artist $id',
  'images': [
    {'url': 'https://img/$id.jpg', 'width': 320, 'height': 320},
  ],
};

void main() {
  group('scope が足りているかの判定', () {
    test('scope を記録する前のトークンは再連携が要る', () async {
      // spotify_granted_scopes を持たない＝この機能より前にログインした状態。
      final auth = signedInAuth();
      await auth.restore();

      expect(auth.needsReauthorization, isTrue);
      expect(auth.missingScopes, contains('user-follow-read'));
    });

    test('現行の scope を全て持っていれば再連携は要らない', () async {
      final auth = signedInAuth(
        extra: {'spotify_granted_scopes': SpotifyConfig.scopes.join(' ')},
      );
      await auth.restore();

      expect(auth.needsReauthorization, isFalse);
      expect(auth.missingScopes, isEmpty);
    });

    test('一部だけ欠けている場合は欠けているものだけを挙げる', () async {
      final partial = SpotifyConfig.scopes
          .where((s) => s != 'user-follow-read')
          .join(' ');
      final auth = signedInAuth(extra: {'spotify_granted_scopes': partial});
      await auth.restore();

      expect(auth.missingScopes, {'user-follow-read'});
    });

    test('未ログインなら再連携バナーは出さない', () async {
      final auth = AuthService(storage: FakeStorage({}));
      await auth.restore();

      expect(auth.isSignedIn, isFalse);
      // scope は空なので missingScopes は埋まるが、出す相手がいない。
      expect(auth.needsReauthorization, isFalse);
    });

    test('サインアウトで scope の記録も消える', () async {
      final values = {
        'spotify_refresh_token': 'rt-1',
        'spotify_granted_scopes': SpotifyConfig.scopes.join(' '),
      };
      final auth = AuthService(storage: FakeStorage(values));
      await auth.restore();
      await auth.signOut();

      expect(values.containsKey('spotify_granted_scopes'), isFalse);
      expect(auth.needsReauthorization, isFalse);
    });
  });

  group('403 の切り分け', () {
    test('Insufficient client scope は SpotifyScopeException', () async {
      final api = apiWith(
        FakeAdapter(
          (_) => _json({
            'error': {'status': 403, 'message': 'Insufficient client scope'},
          }, status: 403),
        ),
      );

      await expectLater(
        api.followedArtists(),
        throwsA(isA<SpotifyScopeException>()),
      );
    });

    // /playlists/* の書き込みは、scope が足りなくても素の "Forbidden" しか
    // 返ってこない。文面では切り分けられないので、控えの scope で判断する。
    SpotifyApi playlistApi({
      required bool hasWriteScope,
      bool verified = true,
    }) {
      final dio =
          Dio(
              BaseOptions(
                baseUrl: SpotifyConfig.apiBaseUrl,
                validateStatus: (_) => true,
              ),
            )
            ..httpClientAdapter = FakeAdapter(
              (_) => _json({
                'error': {'status': 403, 'message': 'Forbidden'},
              }, status: 403),
            );
      final granted = hasWriteScope
          ? SpotifyConfig.scopes
          : SpotifyConfig.scopes
                .where((s) => !s.startsWith('playlist-modify'))
                .toList();
      return SpotifyApi(
        signedInAuth(
          extra: {
            'spotify_granted_scopes': granted.join(' '),
            // キーが有る＝ Spotify が実際に返してきた scope を控えている。
            if (verified) 'spotify_granted_scopes_verified': '1',
          },
        ),
        dio: dio,
      );
    }

    test('書き込みの scope が無い状態の Forbidden は再連携として扱う', () async {
      final api = playlistApi(hasWriteScope: false);

      await expectLater(
        api.addTrackToPlaylist('p1', 'spotify:track:t1'),
        throwsA(isA<SpotifyScopeException>()),
      );
    });

    // 控えが仮定のままだと「権限はあるはずなのに 403」で手が止まる。
    // 403 のほうが実測なので、控えを落として再連携へ倒す。
    test('控えが未確認なら、Forbidden を実測として控えを落とす', () async {
      final api = playlistApi(hasWriteScope: true, verified: false);

      await expectLater(
        api.addTrackToPlaylist('p1', 'spotify:track:t1'),
        throwsA(isA<SpotifyScopeException>()),
      );
      // 次からは叩く前に「権限が足りない」と分かる。
      expect(api.missingScopes, {
        'playlist-modify-public',
        'playlist-modify-private',
      });
    });

    test('Spotify 確認済みの scope で拒否されたら、再連携を勧めない', () async {
      final api = playlistApi(hasWriteScope: true);

      await expectLater(
        api.removeTrackFromPlaylist('p1', 'spotify:track:t1'),
        throwsA(
          isA<SpotifyApiException>()
              .having(
                (e) => e is SpotifyScopeException,
                'scope 例外ではない',
                isFalse,
              )
              // 非公開かどうかの話ではないので、そこへ誘導しない。
              .having((e) => e.message, '文面', contains('編集できません'))
              .having((e) => e.message, '再連携を勧めない', isNot(contains('再連携'))),
        ),
      );
      // 控えは実測なので落とさない（何度再連携させても直らないため）。
      expect(api.missingScopes, isEmpty);
    });

    test('Premium 由来の 403 は素通しする', () async {
      final api = apiWith(
        FakeAdapter(
          (_) => _json({
            'error': {'status': 403, 'message': 'Player command failed'},
          }, status: 403),
        ),
      );

      await expectLater(
        api.followedArtists(),
        throwsA(
          isA<SpotifyApiException>().having(
            (e) => e is SpotifyScopeException,
            'scope 例外ではない',
            isFalse,
          ),
        ),
      );
    });
  });

  group('followedArtists のページング', () {
    test('next を追って全ページ集める', () async {
      final adapter = FakeAdapter((options) {
        final after = options.queryParameters['after'];
        if (after == null) {
          return _json({
            'artists': {
              'items': [_artist('a1'), _artist('a2')],
              'next': 'https://api.spotify.com/v1/me/following?after=a2',
              'cursors': {'after': 'a2'},
            },
          });
        }
        return _json({
          'artists': {
            'items': [_artist('a3')],
            'next': null,
            'cursors': {'after': 'a3'},
          },
        });
      });

      final artists = await apiWith(adapter).followedArtists();

      expect(artists.map((a) => a.id), ['a1', 'a2', 'a3']);
      expect(adapter.requests.length, 2);
      // 2 ページ目は 1 ページ目の cursor を持って行く。
      expect(adapter.requests[1].queryParameters['after'], 'a2');
      expect(adapter.requests.first.queryParameters['type'], 'artist');
    });

    test('MusicBrainz を引くためのキーを組み立てられる', () async {
      final adapter = FakeAdapter(
        (_) => _json({
          'artists': {
            'items': [_artist('4Z8W4fKeB5YxbusRsdQVPb')],
            'next': null,
          },
        }),
      );

      final artists = await apiWith(adapter).followedArtists();

      expect(
        artists.single.musicBrainzLookupUrl,
        'https://open.spotify.com/artist/4Z8W4fKeB5YxbusRsdQVPb',
      );
      expect(
        artists.single.artworkUrl,
        'https://img/4Z8W4fKeB5YxbusRsdQVPb.jpg',
      );
    });

    test('next はあるのに cursor が無ければ打ち切る（無限ループにしない）', () async {
      final adapter = FakeAdapter(
        (_) => _json({
          'artists': {
            'items': [_artist('a1')],
            'next': 'https://api.spotify.com/v1/me/following?after=a1',
            'cursors': <String, dynamic>{},
          },
        }),
      );

      final artists = await apiWith(adapter).followedArtists();

      expect(artists.map((a) => a.id), ['a1']);
      expect(adapter.requests.length, 1);
    });

    test('cursor が進まなくても打ち切る', () async {
      final adapter = FakeAdapter(
        (_) => _json({
          'artists': {
            'items': [_artist('a1')],
            'next': 'https://api.spotify.com/v1/me/following?after=a1',
            'cursors': {'after': 'a1'},
          },
        }),
      );

      await apiWith(adapter).followedArtists();

      // 1 回目で after=null、2 回目で after=a1、その後は進まないので停止。
      expect(adapter.requests.length, lessThanOrEqualTo(2));
    });
  });
}
