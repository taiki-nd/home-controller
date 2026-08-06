import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/musicbrainz_api.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/new_releases_controller.dart';
import 'package:spotify_remote/state/player_controller.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/phone_layout.dart';
import 'package:spotify_remote/ui/widgets/panels.dart';

/// 再生中の曲をプレイリストに入れる / 外す。
///
/// 「入っているか」は context（再生元）だけで決めている。ここが崩れると
/// ボタンが嘘をつくので、context の形ごとに判定を固定しておく。

const _track = Track(
  id: 'cur',
  uri: 'spotify:track:cur',
  name: 'Midnight City',
  artists: 'M83',
  albumName: 'Hurry Up, We are Dreaming',
  durationMs: 244000,
);

const _mine = PlaylistSummary(
  id: 'p1',
  uri: 'spotify:playlist:p1',
  name: 'Party 2026',
  ownerName: 'You',
  ownerId: 'me',
  trackCount: 84,
);

const _alsoMine = PlaylistSummary(
  id: 'p2',
  uri: 'spotify:playlist:p2',
  name: '日曜の朝',
  ownerName: 'You',
  ownerId: 'me',
  trackCount: 42,
);

const _someoneElses = PlaylistSummary(
  id: 'p3',
  uri: 'spotify:playlist:p3',
  name: 'Late Night Drive',
  ownerName: 'だれか',
  ownerId: 'other',
  trackCount: 120,
);

/// Spotify 製（Discover Weekly 等）。ライブラリに並ぶが誰も書き換えられない。
const _madeForYou = PlaylistSummary(
  id: 'dw',
  uri: 'spotify:playlist:dw',
  name: 'Discover Weekly',
  ownerName: 'Spotify',
  ownerId: PlaylistSummary.spotifyOwnerId,
  trackCount: 30,
);

class _FakeApi extends SpotifyApi {
  _FakeApi({
    this.contextUri = 'spotify:playlist:p1',
    this.userId = 'me',
    this.missing = const {},
    this.forbid = const {},
  }) : super(AuthService());

  final String? contextUri;
  final String? userId;

  /// トークンに足りない scope。既定は「揃っている」。
  final Set<String> missing;

  /// 書き込むと 403 を返すプレイリスト id（Spotify 側が拒否する状況の再現）。
  final Set<String> forbid;

  @override
  Set<String> get missingScopes => missing;

  /// 書き込みの記録。`add:<playlistId>:<trackUri>` / `remove:…`。
  final List<String> writes = [];

  @override
  Future<PlaybackState> playbackState() async => PlaybackState(
    isPlaying: true,
    progressMs: 1000,
    shuffleState: false,
    hasContent: true,
    track: _track,
    device: const SpotifyDevice(
      id: 'wiim',
      name: 'WiiM Ultra',
      kind: SpotifyDeviceKind.speaker,
      isActive: true,
      isRestricted: false,
      volumePercent: 42,
    ),
    contextUri: contextUri,
  );

  @override
  Future<QueueSnapshot> queue() async => QueueSnapshot.empty;

  @override
  Future<List<SpotifyDevice>> devices() async => const [
    SpotifyDevice(
      id: 'wiim',
      name: 'WiiM Ultra',
      kind: SpotifyDeviceKind.speaker,
      isActive: true,
      isRestricted: false,
      volumePercent: 42,
    ),
  ];

  @override
  Future<List<PlaylistSummary>> playlists({int limit = 50}) async => const [
    _mine,
    _alsoMine,
    _someoneElses,
    _madeForYou,
  ];

  @override
  Future<String?> currentUserId() async => userId;

  /// Spotify が拒否する状況。文面は本物と同じく素の Forbidden 由来のもの。
  void _rejectIfForbidden(String playlistId) {
    if (!forbid.contains(playlistId)) return;
    throw SpotifyApiException('このプレイリストは編集できません。', statusCode: 403);
  }

  @override
  Future<void> addTrackToPlaylist(String playlistId, String trackUri) async {
    _rejectIfForbidden(playlistId);
    writes.add('add:$playlistId:$trackUri');
  }

  @override
  Future<void> removeTrackFromPlaylist(
    String playlistId,
    String trackUri,
  ) async {
    _rejectIfForbidden(playlistId);
    writes.add('remove:$playlistId:$trackUri');
  }
}

/// start() は playlists / user id を unawaited で投げるので、1 度手を離して待つ。
///
/// **[tester] を渡すこと（widget テストの場合）。** testWidgets の中の
/// `Future.delayed` は FakeAsync のタイマーになるので、pump しない限り永久に
/// 完了せず、そこで固まる。
Future<PlayerController> _boot(_FakeApi api, {WidgetTester? tester}) async {
  final controller = PlayerController(api);
  addTearDown(controller.dispose);
  await controller.start();
  if (tester == null) {
    await Future<void>.delayed(Duration.zero);
  } else {
    await tester.pump();
  }
  controller.setForeground(false);
  return controller;
}

NewReleasesController _idleReleases() =>
    NewReleasesController(_NeverApi(AuthService()), MusicBrainzApi());

class _NeverApi extends SpotifyApi {
  _NeverApi(super.auth);

  @override
  Future<List<FollowedArtist>> followedArtists() =>
      throw StateError('このテストで followedArtists は呼ばれない');
}

/// コントローラの変更でちゃんと描き替わる形で包む（本番の ControllerScreen 相当）。
Widget _wrap(PlayerController controller, Widget Function() build, Size size) =>
    MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox.fromSize(
            size: size,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => build(),
            ),
          ),
        ),
      ),
    );

void main() {
  const iphone = Size(390, 844);

  group('入っているかの判定は context だけで決める', () {
    test('再生元が自分のプレイリストなら、そのリストを指す', () async {
      final controller = await _boot(_FakeApi());
      expect(controller.currentTrackPlaylist?.id, 'p1');
    });

    test('再生元が他人のプレイリストなら null（消せないので削除も出さない）', () async {
      final controller = await _boot(
        _FakeApi(contextUri: 'spotify:playlist:p3'),
      );
      expect(controller.currentTrackPlaylist, isNull);
    });

    test('再生元がアルバムや検索なら null', () async {
      final controller = await _boot(_FakeApi(contextUri: 'spotify:album:a1'));
      expect(controller.currentTrackPlaylist, isNull);

      final noContext = await _boot(_FakeApi(contextUri: null));
      expect(noContext.currentTrackPlaylist, isNull);
    });

    test('手元の一覧に無い context（エディトリアル等）なら null', () async {
      final controller = await _boot(
        _FakeApi(contextUri: 'spotify:playlist:unknown'),
      );
      expect(controller.currentTrackPlaylist, isNull);
    });

    test('自分の id が取れなければ、編集可否を絞らない', () async {
      final controller = await _boot(
        _FakeApi(contextUri: 'spotify:playlist:p3', userId: null),
      );
      expect(controller.currentTrackPlaylist?.id, 'p3');
      expect(controller.editablePlaylists, hasLength(3));
    });
  });

  test('追加先の候補は編集できるリストだけ', () async {
    final controller = await _boot(_FakeApi());
    expect(controller.editablePlaylists.map((p) => p.id), ['p1', 'p2']);
    // 他人のもの（p3）と Spotify 製（dw）の 2 件。
    expect(controller.readOnlyPlaylistCount, 2);
  });

  test('削除すると API を叩き、手元の曲数も減る', () async {
    final api = _FakeApi();
    final controller = await _boot(api);
    await controller.removeFromPlaylist(_mine, _track);

    expect(api.writes, ['remove:p1:spotify:track:cur']);
    expect(controller.playlists.firstWhere((p) => p.id == 'p1').trackCount, 83);
    expect(controller.toast, contains('Party 2026 から削除'));
  });

  test('追加すると API を叩き、手元の曲数も増える', () async {
    final api = _FakeApi();
    final controller = await _boot(api);
    controller.beginAddToPlaylist(_track);
    expect(controller.addingTrack, _track);
    expect(controller.tab, RailTab.playlists);

    await controller.addToPlaylist(_alsoMine, _track);

    expect(api.writes, ['add:p2:spotify:track:cur']);
    expect(controller.addingTrack, isNull, reason: '選び終わったらモードは畳む');
    expect(controller.playlists.firstWhere((p) => p.id == 'p2').trackCount, 43);
  });

  group('編集できないリストは出さない', () {
    // Discover Weekly / Daily Mix / Blend などは自分のライブラリに並ぶが、
    // 誰も中身を書き換えられない。自分の id が取れていなくてもこれは分かる。
    test('Spotify 製のリストは、自分の id が取れていなくても候補から落とす', () async {
      const madeForYou = PlaylistSummary(
        id: 'dw',
        uri: 'spotify:playlist:dw',
        name: 'Discover Weekly',
        ownerName: 'Spotify',
        ownerId: PlaylistSummary.spotifyOwnerId,
        trackCount: 30,
      );

      expect(madeForYou.isEditableBy(null), isFalse);
      expect(madeForYou.isEditableBy('me'), isFalse);
    });

    test('Spotify 製のリストを流していても削除の導線を出さない', () async {
      final controller = await _boot(
        _FakeApi(contextUri: 'spotify:playlist:dw', userId: null),
      );
      expect(controller.currentTrackPlaylist, isNull);
    });

    // /me/playlists は「書き換えられるか」を返してくれない。所有者で弾いても
    // 取りこぼす（他人のリストは id が無いと分からない）ので、403 を実測として覚える。
    test('403 を食らったリストは、次から候補にも ✓ にも出さない', () async {
      final api = _FakeApi(forbid: const {'p1'});
      final controller = await _boot(api);
      expect(controller.currentTrackPlaylist?.id, 'p1', reason: '拒否される前は出る');

      await controller.removeFromPlaylist(_mine, _track);

      expect(controller.errorBanner, isNotNull);
      expect(controller.currentTrackPlaylist, isNull);
      expect(controller.editablePlaylists.map((p) => p.id), ['p2']);
    });

    // 「自分が作ったのに編集できない」の実際の中身は、たいていログイン中の
    // アカウントが所有者ではないこと。突き合わせた結果を文面に出す。
    test('所有者が別アカウントなら、その id を並べて名指しする', () async {
      final api = _FakeApi(forbid: const {'p3'});
      final controller = await _boot(api);

      await controller.addToPlaylist(_someoneElses, _track);

      expect(controller.errorBanner, contains('other'));
      expect(controller.errorBanner, contains('me'));
      expect(controller.errorBanner, contains('フォローしているだけ'));
    });

    test('所有者も権限も揃っているのに拒否されたら、手元の問題ではないと言う', () async {
      final api = _FakeApi(forbid: const {'p1'});
      final controller = await _boot(api);

      await controller.addToPlaylist(_mine, _track);

      expect(controller.errorBanner, contains('Spotify が拒否'));
      expect(controller.errorBanner, isNot(contains('フォローしているだけ')));
    });
  });

  group('scope が足りないときは叩かずに理由を出す', () {
    // /playlists/* の 403 は素の "Forbidden" しか返ってこない。それを見せても
    // 何をすればいいのか分からないので、手前で言い切る。
    _FakeApi shortApi() => _FakeApi(missing: const {'playlist-modify-private'});

    test('追加は選択を畳まずに止める（再連携後に選び直せる）', () async {
      final api = shortApi();
      final controller = await _boot(api);
      controller.beginAddToPlaylist(_track);

      await controller.addToPlaylist(_alsoMine, _track);

      expect(api.writes, isEmpty);
      expect(controller.errorBanner, contains('再連携'));
      expect(controller.addingTrack, _track);
    });

    test('削除も止める', () async {
      final api = shortApi();
      final controller = await _boot(api);

      await controller.removeFromPlaylist(_mine, _track);

      expect(api.writes, isEmpty);
      expect(controller.errorBanner, contains('再連携'));
    });
  });

  test('別のタブへ移ると追加モードは畳まれる', () async {
    final controller = await _boot(_FakeApi());
    controller.beginAddToPlaylist(_track);
    controller.selectTab(RailTab.search);
    expect(controller.addingTrack, isNull);
  });

  testWidgets('入っているときは削除、入っていないときは追加の導線が出る', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await _boot(_FakeApi(), tester: tester);
    (PlaylistSummary, Track)? removed;

    await tester.pumpWidget(
      _wrap(
        controller,
        () => PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          onRemoveFromPlaylist: (playlist, track) =>
              removed = (playlist, track),
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        iphone,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // context が p1 なので「入っている」＝チェック付きのアイコン。
    expect(find.byIcon(Icons.playlist_add_check_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.playlist_add_check_rounded));
    await tester.pump();

    // 削除は確認を挟むので、ここでは投げ上げるだけ。API は叩かない。
    expect(removed?.$1.id, 'p1');
    expect(removed?.$2.uri, _track.uri);
    expect(controller.addingTrack, isNull);
  });

  testWidgets('入っていないときに押すと、追加先の選択が開く', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = _FakeApi(contextUri: 'spotify:album:a1');
    final controller = await _boot(api, tester: tester);

    await tester.pumpWidget(
      _wrap(
        controller,
        () => PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          onRemoveFromPlaylist: (_, _) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        iphone,
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.playlist_add_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.playlist_add_rounded));
    // pumpAndSettle は使えない。脈打つ点（StatusDot）と OrbitingLight が
    // 回り続けるので永久に settle しない。シートの開き（300ms）ぶんだけ進める。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // 帯に対象の曲を出す。行の意味が変わるので、ここが無いと事故になる。
    expect(find.text('ADD TO PLAYLIST'), findsOneWidget);
    expect(find.text('Midnight City'), findsWidgets);
    // 他人のリストは並べない。
    expect(find.text('Late Night Drive'), findsNothing);

    await tester.tap(find.text('日曜の朝'));
    await tester.pump();

    expect(api.writes, ['add:p2:spotify:track:cur']);

    // 追加のトーストが 2 秒のタイマーを引くので、消えるまで進めてから終わる。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('もう入っているリストの行は押せない', (tester) async {
    final api = _FakeApi();
    final controller = await _boot(api, tester: tester);
    // context = p1 の曲を持ったまま追加モードに入った状態（他クライアントで
    // 再生元が変わると起こり得る）。p1 への再追加は重複になる。
    controller.beginAddToPlaylist(_track);

    await tester.pumpWidget(
      _wrap(
        controller,
        () => SizedBox(
          width: 390,
          height: 700,
          child: PlaylistsPanel(
            controller: controller,
            compact: true,
            onPlay: (_) {},
          ),
        ),
        const Size(390, 844),
      ),
    );
    await tester.pump();

    expect(find.text('IN LIST'), findsOneWidget);
    await tester.tap(find.text('Party 2026'));
    await tester.pump();
    expect(api.writes, isEmpty);

    // 隣の行は普通に押せる。
    await tester.tap(find.text('日曜の朝'));
    await tester.pump();
    expect(api.writes, ['add:p2:spotify:track:cur']);

    // 追加のトーストが 2 秒のタイマーを引くので、消えるまで進めてから終わる。
    await tester.pump(const Duration(seconds: 2));
  });
}
