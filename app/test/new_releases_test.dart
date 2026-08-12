import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/release_models.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/musicbrainz_api.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/new_releases_controller.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/widgets/new_releases_panel.dart';

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

/// throttle を潰した MusicBrainzApi。本番の 1.1 秒はテストには要らない。
MusicBrainzApi mbWith(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = adapter;
  return MusicBrainzApi(dio: dio, minInterval: Duration.zero);
}

/// フォロー一覧だけを差し替えた SpotifyApi。
class FakeFollowApi extends SpotifyApi {
  FakeFollowApi(this.artists) : super(AuthService());

  final List<FollowedArtist> artists;

  @override
  Future<List<FollowedArtist>> followedArtists() async => artists;
}

class ThrowingFollowApi extends SpotifyApi {
  ThrowingFollowApi(this.error) : super(AuthService());

  final SpotifyApiException error;

  @override
  Future<List<FollowedArtist>> followedArtists() async => throw error;
}

/// 呼ばれない前提の MusicBrainz。
class UnusedMusicBrainz extends MusicBrainzApi {
  @override
  Future<Map<String, String>> artistMbidsBySpotifyUrl(
    List<String> urls,
  ) async => throw StateError('呼ばれてはいけない');
}

FollowedArtist artist(String id) =>
    FollowedArtist(id: id, uri: 'spotify:artist:$id', name: 'Artist $id');

NewRelease release(String title, DateTime? date) => NewRelease(
  releaseGroupMbid: title,
  title: title,
  artistName: 'A',
  artistMbids: const [],
  releaseDate: date,
);

void main() {
  group('リリース日の解釈', () {
    test('日まで揃っているものだけ日付にする', () {
      expect(NewRelease.parseDate('2026-08-14'), DateTime(2026, 8, 14));
    });

    test('粒度が粗いものは日付をでっち上げず null にする', () {
      // 「2026-08」を 8/1 に寄せると「あと N 日」が嘘になる。
      expect(NewRelease.parseDate('2026-08'), isNull);
      expect(NewRelease.parseDate('2026'), isNull);
      expect(NewRelease.parseDate(null), isNull);
    });

    test('未発売かどうかは日付の境目で切り替わる', () {
      final now = DateTime(2026, 8, 4, 23, 59);
      expect(release('x', DateTime(2026, 8, 5)).isUpcoming(now), isTrue);
      // 当日は「発売済み」側。もう鳴らせる。
      expect(release('x', DateTime(2026, 8, 4)).isUpcoming(now), isFalse);
      expect(release('x', null).isUpcoming(now), isFalse);
    });
  });

  group('artist-credit の組み立て', () {
    test('joinphrase を挟んで表示名を作る', () {
      final parsed = NewRelease.fromReleaseGroupJson({
        'id': 'rg1',
        'title': 'A ? of WHEN',
        'first-release-date': '2026-07-10',
        'primary-type': 'Album',
        'artist-credit': [
          {
            'name': 'Panda Bear',
            'joinphrase': ' & ',
            'artist': {'id': 'mbid-a'},
          },
          {
            'name': 'Sonic Boom',
            'artist': {'id': 'mbid-b'},
          },
        ],
      });

      expect(parsed!.artistName, 'Panda Bear & Sonic Boom');
      expect(parsed.artistMbids, ['mbid-a', 'mbid-b']);
      expect(
        parsed.coverArtUrl,
        'https://coverartarchive.org/release-group/rg1/front-250',
      );
    });
  });

  group('MusicBrainz のバッチ', () {
    test('arid は 100 件ずつに割る（201 件なら 3 リクエスト）', () async {
      final adapter = FakeAdapter(
        (_) => _json({'count': 0, 'release-groups': <dynamic>[]}),
      );
      final mbids = List.generate(201, (i) => 'mbid-$i');

      await mbWith(adapter).releaseGroups(
        artistMbids: mbids,
        from: DateTime(2026, 7, 5),
        to: DateTime(2026, 11, 2),
      );

      // ここが N+1 を潰している要。1人1リクエストなら 201 回になる。
      expect(adapter.requests.length, 3);
    });

    test('クエリに期間とタイプの絞り込みが乗る', () async {
      final adapter = FakeAdapter(
        (_) => _json({'count': 0, 'release-groups': <dynamic>[]}),
      );

      await mbWith(adapter).releaseGroups(
        artistMbids: ['mbid-1'],
        from: DateTime(2026, 7, 5),
        to: DateTime(2026, 11, 2),
      );

      final query = adapter.requests.single.queryParameters['query'] as String;
      expect(query, contains('arid:(mbid-1)'));
      expect(query, contains('firstreleasedate:[2026-07-05 TO 2026-11-02]'));
      expect(query, contains('primarytype:(Album OR EP OR Single)'));
      // 二次タイプを一律に弾くと Remix まで落ちる。除外は名指しで。
      expect(query, isNot(contains('-secondarytype:*')));
      expect(query, contains('-secondarytype:('));
      expect(query, contains('Compilation OR Live'));
      expect(query, isNot(contains('Remix')));
    });

    test('User-Agent を必ず載せる（無いと 403）', () async {
      final adapter = FakeAdapter(
        (_) => _json({'count': 0, 'release-groups': <dynamic>[]}),
      );

      await mbWith(adapter).releaseGroups(
        artistMbids: ['mbid-1'],
        from: DateTime(2026, 7, 5),
        to: DateTime(2026, 11, 2),
      );

      expect(adapter.requests.single.headers['User-Agent'], isNotNull);
    });

    test('URL は 50 件ずつに割り、relation から MBID を拾う', () async {
      final adapter = FakeAdapter(
        (options) => _json({
          'urls': [
            {
              'resource': 'https://open.spotify.com/artist/s0',
              'relation-list': [
                {
                  'relations': [
                    {
                      'artist': {'id': 'mbid-0', 'name': 'Radiohead'},
                    },
                  ],
                },
              ],
            },
          ],
        }),
      );
      final urls = List.generate(
        120,
        (i) => 'https://open.spotify.com/artist/s$i',
      );

      final resolved = await mbWith(adapter).artistMbidsBySpotifyUrl(urls);

      expect(adapter.requests.length, 3);
      expect(resolved['https://open.spotify.com/artist/s0'], 'mbid-0');
    });

    test('414 は専用の例外にする', () async {
      final adapter = FakeAdapter((_) => _json({}, status: 414));

      await expectLater(
        mbWith(adapter).releaseGroups(
          artistMbids: ['mbid-1'],
          from: DateTime(2026, 7, 5),
          to: DateTime(2026, 11, 2),
        ),
        throwsA(
          isA<MusicBrainzException>().having((e) => e.statusCode, '', 414),
        ),
      );
    });
  });

  group('NewReleasesController', () {
    /// 解決できたぶんだけ MBID を返す MusicBrainz。
    MusicBrainzApi mbReturning({
      required Map<String, String> mbids,
      required List<NewRelease> releases,
    }) {
      final adapter = FakeAdapter((options) {
        if (options.path == '/url') {
          return _json({
            'urls': [
              for (final entry in mbids.entries)
                {
                  'resource': entry.key,
                  'relations': [
                    {
                      'artist': {'id': entry.value},
                    },
                  ],
                },
            ],
          });
        }
        return _json({
          'count': releases.length,
          'release-groups': [
            for (final r in releases)
              {
                'id': r.releaseGroupMbid,
                'title': r.title,
                'first-release-date': r.releaseDate == null
                    ? null
                    : '${r.releaseDate!.year}-'
                          '${r.releaseDate!.month.toString().padLeft(2, '0')}-'
                          '${r.releaseDate!.day.toString().padLeft(2, '0')}',
                'primary-type': 'Album',
                'artist-credit': [
                  {
                    'name': r.artistName,
                    // フォロー側と同じ MBID を返す（そうしないと
                    // spotifyArtistIdsOf が引けない組み合わせになる）。
                    'artist': {
                      'id': mbids.values.isEmpty ? 'mbid-x' : mbids.values.first,
                    },
                  },
                ],
              },
          ],
        });
      });
      return mbWith(adapter);
    }

    test('未発売を近い順に、発売済みを新しい順に並べる', () async {
      final now = DateTime(2026, 8, 4);
      final controller = NewReleasesController(
        FakeFollowApi([artist('s0')]),
        mbReturning(
          mbids: {'https://open.spotify.com/artist/s0': 'mbid-0'},
          releases: [
            release('遠い未来', DateTime(2026, 9, 20)),
            release('古い過去', DateTime(2026, 7, 10)),
            release('近い未来', DateTime(2026, 8, 7)),
            release('最近', DateTime(2026, 8, 1)),
          ],
        ),
        now: () => now,
      );

      await controller.load();

      expect(controller.releases.map((r) => r.title), [
        '近い未来', // 未発売は近い順
        '遠い未来',
        '最近', // 発売済みは新しい順
        '古い過去',
      ]);
      expect(controller.upcoming.map((r) => r.title), ['近い未来', '遠い未来']);
      expect(controller.released.map((r) => r.title), ['最近', '古い過去']);
    });

    test('照合できなかったアーティストを数えて名前も残す', () async {
      final controller = NewReleasesController(
        FakeFollowApi([artist('s0'), artist('s1'), artist('s2')]),
        mbReturning(
          // s1 / s2 は MusicBrainz 側に Spotify の対応付けが無い想定。
          mbids: {'https://open.spotify.com/artist/s0': 'mbid-0'},
          releases: const [],
        ),
        now: () => DateTime(2026, 8, 4),
      );

      await controller.load();

      expect(controller.coverage.followed, 3);
      expect(controller.coverage.resolved, 1);
      expect(controller.coverage.missing, 2);
      expect(controller.unresolvedArtists, ['Artist s1', 'Artist s2']);
    });

    test('新譜を出したアーティストの Spotify id を引けるようにする', () async {
      // 新譜を引くのに使った MBID の対応を捨てないこと。行を押したときの
      // 突き合わせ先（そのアーティストの棚）がこれで決まる。
      final controller = NewReleasesController(
        FakeFollowApi([artist('s0')]),
        mbReturning(
          mbids: {'https://open.spotify.com/artist/s0': 'mbid-0'},
          releases: [release('最近', DateTime(2026, 8, 1))],
        ),
        now: () => DateTime(2026, 8, 4),
      );

      await controller.load();

      expect(controller.spotifyArtistIdsOf(controller.releases.single), ['s0']);
    });

    test('フォローが 0 なら MusicBrainz を叩かない', () async {
      final controller = NewReleasesController(
        FakeFollowApi(const []),
        UnusedMusicBrainz(),
        now: () => DateTime(2026, 8, 4),
      );

      await controller.load();

      expect(controller.status, NewReleasesStatus.ready);
      expect(controller.releases, isEmpty);
    });

    test('scope 不足は failed として出す', () async {
      final controller = NewReleasesController(
        ThrowingFollowApi(SpotifyScopeException()),
        UnusedMusicBrainz(),
        now: () => DateTime(2026, 8, 4),
      );

      await controller.load();

      expect(controller.status, NewReleasesStatus.failed);
      expect(controller.error, isNotNull);
    });

    test('2 回目の load は取り直さない（force で取り直す）', () async {
      final api = _CountingFollowApi([artist('s0')]);
      final controller = NewReleasesController(
        api,
        mbReturning(
          mbids: {'https://open.spotify.com/artist/s0': 'mbid-0'},
          releases: const [],
        ),
        now: () => DateTime(2026, 8, 4),
      );

      await controller.load();
      await controller.load();
      expect(api.calls, 1);

      await controller.load(force: true);
      expect(api.calls, 2);
    });
  });

  group('ReleaseResolver', () {
    test('そのアーティストの棚から選ぶ（MusicBrainz へは行かない）', () async {
      final spotify = FakeShelfApi(
        shelves: {
          'ado': [album('ギラギラ'), album('唱')],
        },
      );
      final mb = FakeLinkMb({});

      final match = await ReleaseResolver(spotify, mb).resolve(
        mbRelease(title: '唱'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match?.name, '唱');
      // 棚で当たったら 2 本目の経路は使わない。
      expect(mb.asked, isEmpty);
    });

    test('別のアーティストの盤は候補にすら入らない', () async {
      // これが「押したら全く関係ない曲が鳴る」の正体だった。全文検索をやめて
      // 棚を引くようにしたので、同名タイトルの他人の盤は見えない。
      final spotify = FakeShelfApi(shelves: {'ado': []});

      final match = await ReleaseResolver(spotify, FakeLinkMb({})).resolve(
        mbRelease(title: '唱'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match, isNull);
      expect(spotify.askedArtists, ['ado']);
    });

    test('棚で当たらなければ MusicBrainz の配信リンクから id 直結で拾う', () async {
      // MB は日本語表記・Spotify は英字表記、のような食い違い。
      final spotify = FakeShelfApi(
        shelves: {'ado': [album('Sho')]},
        albumsById: {'sp-album-1': album('Sho', id: 'sp-album-1')},
      );
      final mb = FakeLinkMb({'rg-唱': ['sp-album-1']});

      final match = await ReleaseResolver(spotify, mb).resolve(
        mbRelease(title: '唱'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match?.id, 'sp-album-1');
      expect(mb.asked, ['rg-唱']);
    });

    test('どちらの経路も外れたら null を返す', () async {
      // Spotify にまだ無い新譜。**関連度 1 位で妥協しない。**
      final spotify = FakeShelfApi(shelves: {'ado': [album('別のアルバム')]});

      final match = await ReleaseResolver(spotify, FakeLinkMb({})).resolve(
        mbRelease(title: '新曲'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match, isNull);
    });

    test('リンクが消えた id は無かったことにする', () async {
      // MB のリンクは残っているが Spotify 側から消えた盤（404）。
      final spotify = FakeShelfApi(shelves: {'ado': []});
      final mb = FakeLinkMb({'rg-唱': ['sp-dead']});

      final match = await ReleaseResolver(spotify, mb).resolve(
        mbRelease(title: '唱'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match, isNull);
    });

    test('後ろに付いたエディション表記は許す', () async {
      final spotify = FakeShelfApi(
        shelves: {'aimer': [album('残響散歌 - Single')]},
      );

      final match = await ReleaseResolver(spotify, FakeLinkMb({})).resolve(
        mbRelease(title: '残響散歌'),
        spotifyArtistIds: const ['aimer'],
      );

      expect(match?.name, '残響散歌 - Single');
    });

    test('エディション表記でない続きは別物として落とす', () async {
      // 同じアーティストでも "Best" で "Best of 〜" を掴めば別物が鳴る。
      final spotify = FakeShelfApi(shelves: {'ado': [album('Best of Ado')]});

      final match = await ReleaseResolver(spotify, FakeLinkMb({})).resolve(
        mbRelease(title: 'Best'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match, isNull);
    });

    test('正規化で空に潰れるタイトルでは棚を引かない', () async {
      // 空文字同士を一致と見なすと、棚の中で手当たり次第に当たってしまう。
      // id 直結の 2 本目だけは進む。
      final spotify = FakeShelfApi(shelves: {'ado': [album('++')]});
      final mb = FakeLinkMb({});

      final match = await ReleaseResolver(spotify, mb).resolve(
        mbRelease(title: '+++'),
        spotifyArtistIds: const ['ado'],
      );

      expect(match, isNull);
      expect(spotify.askedArtists, isEmpty);
      expect(mb.asked, ['rg-+++']);
    });

    test('アーティストが分からなくても配信リンクだけで当てにいく', () async {
      // フォローしていない共作相手の盤など、Spotify の id が引けない場合。
      final spotify = FakeShelfApi(
        shelves: const {},
        albumsById: {'sp-album-1': album('Reset', id: 'sp-album-1')},
      );
      final mb = FakeLinkMb({'rg-Reset': ['sp-album-1']});

      final match = await ReleaseResolver(spotify, mb).resolve(
        mbRelease(title: 'Reset'),
      );

      expect(match?.id, 'sp-album-1');
    });
  });

  group('パネルの描画', _panelTests);
}

/// 棚（`/artists/{id}/albums`）とアルバム単体を差し替えた SpotifyApi。
/// 何を訊かれたかも見る。
class FakeShelfApi extends SpotifyApi {
  FakeShelfApi({
    required this.shelves,
    this.albumsById = const {},
  }) : super(AuthService());

  final Map<String, List<SpotifyAlbumMatch>> shelves;
  final Map<String, SpotifyAlbumMatch> albumsById;
  final List<String> askedArtists = [];

  @override
  Future<List<SpotifyAlbumMatch>> artistAlbums(
    String artistId, {
    int limit = 50,
  }) async {
    askedArtists.add(artistId);
    return shelves[artistId] ?? const [];
  }

  @override
  Future<SpotifyAlbumMatch?> album(String albumId) async =>
      albumsById[albumId];
}

/// 配信リンクだけを持つ MusicBrainz。
class FakeLinkMb extends MusicBrainzApi {
  FakeLinkMb(this.idsByReleaseGroup);

  final Map<String, List<String>> idsByReleaseGroup;
  final List<String> asked = [];

  @override
  Future<List<String>> spotifyAlbumIds(String releaseGroupMbid) async {
    asked.add(releaseGroupMbid);
    return idsByReleaseGroup[releaseGroupMbid] ?? const [];
  }
}

SpotifyAlbumMatch album(String name, {String? id}) => SpotifyAlbumMatch(
  id: id ?? name,
  uri: 'spotify:album:$name',
  name: name,
  artists: 'unused',
  totalTracks: 1,
);

NewRelease mbRelease({required String title}) => NewRelease(
  releaseGroupMbid: 'rg-$title',
  title: title,
  artistName: 'unused',
  artistMbids: const [],
);

class _CountingFollowApi extends SpotifyApi {
  _CountingFollowApi(this.artists) : super(AuthService());

  final List<FollowedArtist> artists;
  int calls = 0;

  @override
  Future<List<FollowedArtist>> followedArtists() async {
    calls++;
    return artists;
  }
}

/// パネルの実寸描画。ここでオーバーフローすると本番でも赤縞が出る。
void _panelTests() {
  Widget wrap(Widget child, Size size) => MediaQuery(
    data: MediaQueryData(size: size),
    child: MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.bg,
        body: SizedBox.fromSize(
          size: size,
          child: Padding(padding: const EdgeInsets.all(18), child: child),
        ),
      ),
    ),
  );

  /// s0 だけが MusicBrainz に対応づいている状態。[followed] を渡すと母集団を
  /// 増やせる（照合から漏れた名前の出し方を見るため）。
  NewReleasesController loaded({List<FollowedArtist>? followed}) {
    final adapter = FakeAdapter((options) {
      if (options.path == '/url') {
        return _json({
          'urls': [
            {
              'resource': 'https://open.spotify.com/artist/s0',
              'relations': [
                {
                  'artist': {'id': 'mbid-0'},
                },
              ],
            },
          ],
        });
      }
      return _json({
        'count': 2,
        'release-groups': [
          {
            'id': 'rg-future',
            'title': 'Melting Days',
            'first-release-date': '2026-08-21',
            'primary-type': 'Album',
            'artist-credit': [
              {
                'name': 'Lusine',
                'artist': {'id': 'mbid-0'},
              },
            ],
          },
          {
            'id': 'rg-past',
            'title': 'Frozen Charlotte',
            'first-release-date': '2026-07-29',
            'primary-type': 'Album',
            'artist-credit': [
              {
                'name': 'Jack White',
                'artist': {'id': 'mbid-0'},
              },
            ],
          },
        ],
      });
    });
    return NewReleasesController(
      FakeFollowApi(followed ?? [artist('s0'), artist('s9')]),
      mbWith(adapter),
      now: () => DateTime(2026, 8, 4),
    );
  }

  Widget panel(NewReleasesController controller, Size size) => wrap(
    NewReleasesPanel(
      controller: controller,
      compact: size.width < 420,
      onPlay: (_) {},
      now: () => DateTime(2026, 8, 4),
    ),
    size,
  );

  testWidgets('照合できなかったアーティストを名前で出す', (tester) async {
    const size = Size(452, 834);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(panel(loaded(), size));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.textContaining('対応付けが無いため'),
      find.byType(ListView),
      const Offset(0, -60),
    );

    // 「1 組漏れた」だけでは誰か分からない。名前まで出す。
    expect(find.text('Artist s9'), findsOneWidget);
  });

  testWidgets('漏れが多いときは畳んで、押すと残りを出す', (tester) async {
    const size = Size(452, 834);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // s0 だけ対応づき、s1〜s12 の 12 組が漏れる。
    final controller = loaded(
      followed: [artist('s0'), for (var i = 1; i <= 12; i++) artist('s$i')],
    );
    await tester.pumpWidget(panel(controller, size));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.textContaining('対応付けが無いため'),
      find.byType(ListView),
      const Offset(0, -60),
    );

    // 8 組まで出して、残り 4 組は畳む。
    expect(find.textContaining('Artist s1、'), findsOneWidget);
    expect(find.text('ほか 4 組を表示'), findsOneWidget);

    await tester.tap(find.text('ほか 4 組を表示'));
    await tester.pumpAndSettle();

    expect(find.text('畳む'), findsOneWidget);
    expect(find.textContaining('Artist s9'), findsOneWidget);
  });

  for (final (name, size) in [
    ('iPad', const Size(452, 834)),
    ('iPhone', const Size(390, 700)),
  ]) {
    testWidgets('$name: New パネルが実寸で破綻せず描画される', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(
          NewReleasesPanel(
            controller: loaded(),
            compact: size.width < 420,
            onPlay: (_) {},
            now: () => DateTime(2026, 8, 4),
          ),
          size,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Melting Days'), findsOneWidget);
      expect(find.text('Frozen Charlotte'), findsOneWidget);
      // 未発売 / 発売済みの見出しが両方出る。
      expect(find.text('COMING SOON'), findsOneWidget);
      expect(find.text('JUST OUT'), findsOneWidget);
      // 未発売は「あと N 日」。
      expect(find.text('あと17日'), findsOneWidget);
      // 照合できなかった 1 組を黙って捨てない。
      expect(find.textContaining('2 組中 1 組'), findsOneWidget);
    });
  }
}
