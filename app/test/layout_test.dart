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
import 'package:spotify_remote/ui/tablet_layout.dart';
import 'package:spotify_remote/ui/widgets/atoms.dart';
import 'package:spotify_remote/ui/widgets/overlays.dart';
import 'package:spotify_remote/ui/widgets/transport.dart';

/// 実際に鳴っている状態を再現する差し替え API。
/// artworkUrl は null にしてある（テスト環境で Image.network を踏ませないため）。
class _FakeApi extends SpotifyApi {
  _FakeApi({required this.playing, this.title = 'Midnight City'})
    : super(AuthService());

  final bool playing;

  /// 曲名の長さでレイアウトが動かないことを見るために差し替えられるようにしてある。
  final String title;

  /// 曲送りの呼び出し記録（'next' / 'previous'）。
  final List<String> commands = [];

  @override
  Future<void> next() async => commands.add('next');

  @override
  Future<void> previous() async => commands.add('previous');

  static Track _track(String id, String name, String artist) => Track(
    id: id,
    uri: 'spotify:track:$id',
    name: name,
    artists: artist,
    albumName: 'Album',
    durationMs: 244000,
  );

  @override
  Future<PlaybackState> playbackState() async {
    if (!playing) return PlaybackState.stopped;
    return PlaybackState(
      isPlaying: true,
      progressMs: 62000,
      shuffleState: false,
      hasContent: true,
      track: _track('cur', title, 'M83'),
      device: const SpotifyDevice(
        id: 'wiim',
        name: 'WiiM Ultra',
        kind: SpotifyDeviceKind.speaker,
        isActive: true,
        isRestricted: false,
        volumePercent: 42,
      ),
      contextUri: 'spotify:playlist:p1',
    );
  }

  @override
  Future<QueueSnapshot> queue() async => QueueSnapshot(
    upcoming: playing
        ? [
            _track('n1', 'Get Lucky', 'Daft Punk'),
            _track('n2', 'Blinding Lights', 'The Weeknd'),
            _track('n3', 'Redbone', 'Childish Gambino'),
          ]
        : const [],
  );

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
    PlaylistSummary(
      id: 'p1',
      uri: 'spotify:playlist:p1',
      name: 'Party 2026',
      ownerName: 'You',
      trackCount: 42,
    ),
  ];
}

Future<PlayerController> buildController(
  WidgetTester tester, {
  required bool playing,
  String title = 'Midnight City',
  SpotifyApi? api,
}) async {
  final controller = PlayerController(
    api ?? _FakeApi(playing: playing, title: title),
  );
  addTearDown(controller.dispose);
  await controller.start();
  // start() が 1 秒間隔のポーリングと 500ms の進捗ティッカーを仕込むので、
  // テストではバックグラウンド扱いにして止める（そうしないと Timer が残る）。
  controller.setForeground(false);
  await tester.pump();
  return controller;
}

Widget wrap(Widget child, Size size) => MediaQuery(
  data: MediaQueryData(size: size),
  child: MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: SizedBox.fromSize(size: size, child: child)),
  ),
);

/// New タブはここでは開かないので、通信に出ない空のコントローラで足りる。
NewReleasesController _idleReleases() =>
    NewReleasesController(_NeverApi(AuthService()), MusicBrainzApi());

/// 呼ばれたら気づけるように、通信ではなく例外で落とす。
class _NeverApi extends SpotifyApi {
  _NeverApi(super.auth);

  @override
  Future<List<FollowedArtist>> followedArtists() =>
      throw StateError('layout テストで followedArtists が呼ばれた');
}

void main() {
  // デザインの実寸。ここでオーバーフローすると本番でも赤縞が出る。
  const ipad = Size(1194, 834);
  const iphone = Size(390, 844);

  testWidgets('iPad レイアウトが実寸で破綻せず描画される', (tester) async {
    tester.view.physicalSize = ipad;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await buildController(tester, playing: true);
    await tester.pumpWidget(
      wrap(
        TabletLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        ipad,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Midnight City'), findsOneWidget);
    // アーティストとアルバムは 1 行にまとめている。
    expect(find.text('M83 / Album'), findsOneWidget);
    // Up next カード + 残り 2 曲の見出し。
    expect(find.text('Get Lucky'), findsOneWidget);
    expect(find.text('3 TRACKS AHEAD'), findsOneWidget);
  });

  testWidgets('☰ はデバイスピルの左に、行を増やさずに入る', (tester) async {
    tester.view.physicalSize = ipad;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await buildController(tester, playing: true);
    await tester.pumpWidget(
      wrap(
        TabletLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          menu: MenuButton(onPressed: () {}),
          topInset: 0,
        ),
        ipad,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);

    final menu = find.byType(MenuButton);
    final pillDot = find.byType(StatusDot).first;

    // 同じ行にいる（縦位置が揃っている）。
    expect(
      tester.getCenter(menu).dy,
      moreOrLessEquals(tester.getCenter(pillDot).dy, epsilon: 1),
    );

    // ピルはそのぶん右へずれる。ここが devicePillDotXFor と食い違うと、
    // デバイス一覧のポップオーバーの点が縦に揃わなくなる。
    expect(
      tester.getTopLeft(pillDot).dx,
      moreOrLessEquals(
        TabletLayout.devicePillDotXFor(hasMenu: true),
        epsilon: 0.5,
      ),
    );
  });

  testWidgets('iPhone レイアウトが実寸で破綻せず描画される', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await buildController(tester, playing: true);
    await tester.pumpWidget(
      wrap(
        PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        iphone,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Midnight City'), findsOneWidget);
    // シートは閉じているので NEXT UP の 1 行プレビューだけ出る。
    expect(find.text('Get Lucky'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget);
  });

  // 曲名は長さが読めない。折り返して 2 行になると、その下敷きにしている
  // アートワークの位置が曲ごとにズレる。1 行固定 + 横流しにした狙いはここ。
  const longTitle =
      'Everything In Its Right Place - Extended Instrumental Mix (Remastered 2026)';

  /// 大判アートワーク（キューのサムネイルではない方）の矩形。
  Rect artRect(WidgetTester tester) => tester.getRect(
    find.byWidgetPredicate((w) => w is Artwork && w.size > 200),
  );

  Future<Rect> artRectFor(
    WidgetTester tester,
    Size size, {
    required String title,
    required bool phone,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final controller = await buildController(
      tester,
      playing: true,
      title: title,
    );
    await tester.pumpWidget(
      wrap(
        phone
            ? PhoneLayout(
                controller: controller,
                newReleases: _idleReleases(),
                onPlayNow: (_) {},
                onPlayPlaylist: (_) {},
                onPlayRelease: (_) {},
                attribution: const SizedBox.shrink(),
                topInset: 0,
              )
            : TabletLayout(
                controller: controller,
                newReleases: _idleReleases(),
                onPlayNow: (_) {},
                onPlayPlaylist: (_) {},
                onPlayRelease: (_) {},
                attribution: const SizedBox.shrink(),
                topInset: 0,
              ),
        size,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    return artRect(tester);
  }

  testWidgets('iPad: 曲名が長くてもアートワークの位置が変わらない', (tester) async {
    addTearDown(tester.view.reset);

    final short = await artRectFor(
      tester,
      ipad,
      title: 'Midnight City',
      phone: false,
    );
    final long = await artRectFor(tester, ipad, title: longTitle, phone: false);

    expect(long, short);
    // 長い方は流れるテキストになっている（= 折り返していない）。
    expect(find.text(longTitle), findsOneWidget);
  });

  testWidgets('iPhone: 曲名が長くてもアートワークの位置が変わらない', (tester) async {
    addTearDown(tester.view.reset);

    final short = await artRectFor(
      tester,
      iphone,
      title: 'Midnight City',
      phone: true,
    );
    final long = await artRectFor(
      tester,
      iphone,
      title: longTitle,
      phone: true,
    );

    expect(long, short);
    expect(find.text(longTitle), findsOneWidget);
  });

  /// カバー画像を [dx] ぶん払う。速度が乗って弾き判定にならないよう小刻みに動かす。
  Future<void> swipeArtwork(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(artRect(tester).center);
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(Offset(dx / 6, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    // skipNext() は 400ms 待ってから再ポーリングするので、そのぶん進めておく。
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('iPhone: カバー画像を左に払うと次の曲へ', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = _FakeApi(playing: true);
    final controller = await buildController(tester, playing: true, api: api);
    await tester.pumpWidget(
      wrap(
        PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        iphone,
      ),
    );
    await tester.pump();

    final before = artRect(tester);
    await swipeArtwork(tester, -120);
    expect(api.commands, ['next']);

    // 払い終わったらカバーは元の位置に戻る（脈打つドットが止まらないので
    // pumpAndSettle は使えない。出入りのアニメより長く進めるだけにする）。
    await tester.pump(const Duration(milliseconds: 600));
    expect(artRect(tester), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iPad: カバー画像を右に払うと前の曲へ', (tester) async {
    tester.view.physicalSize = ipad;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = _FakeApi(playing: true);
    final controller = await buildController(tester, playing: true, api: api);
    await tester.pumpWidget(
      wrap(
        TabletLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        ipad,
      ),
    );
    await tester.pump();

    await swipeArtwork(tester, 160);
    expect(api.commands, ['previous']);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('カバー画像を少しだけ動かしたら曲送りしない', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = _FakeApi(playing: true);
    final controller = await buildController(tester, playing: true, api: api);
    await tester.pumpWidget(
      wrap(
        PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        iphone,
      ),
    );
    await tester.pump();

    // アートは 342px なのでしきい値は 47px。タッチスロップを引いて 20px 弱。
    await swipeArtwork(tester, -38);
    expect(api.commands, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  // デバイス一覧の点は、ピルの点の真下に落ちていないと横にずれて見える。
  // 配置は controller_screen が「ピルの点の x - DevicePopover.dotInset」で決めて
  // いるので、その両端（宣言した x と、箱の中の点の位置）を実測で押さえておく。
  testWidgets('iPad: デバイスピルの点は宣言した x にいる', (tester) async {
    tester.view.physicalSize = ipad;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await buildController(tester, playing: true);
    await tester.pumpWidget(
      wrap(
        TabletLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        ipad,
      ),
    );
    await tester.pump();

    expect(
      tester.getRect(find.byType(StatusDot).first).left,
      TabletLayout.devicePillDotX,
    );
  });

  testWidgets('iPhone: デバイスピルの点は宣言した x にいる', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await buildController(tester, playing: true);
    await tester.pumpWidget(
      wrap(
        PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 0,
        ),
        iphone,
      ),
    );
    await tester.pump();

    expect(
      tester.getRect(find.byType(StatusDot).first).left,
      PhoneLayout.devicePillDotX,
    );
  });

  testWidgets('ポップオーバーの点は宣言したインセットにいる', (tester) async {
    tester.view.physicalSize = ipad;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        Align(
          alignment: Alignment.topLeft,
          child: DevicePopover(
            devices: const [
              SpotifyDevice(
                id: 'wiim',
                name: 'WiiM Ultra',
                kind: SpotifyDeviceKind.speaker,
                isActive: true,
                isRestricted: false,
                volumePercent: 42,
              ),
            ],
            activeDeviceId: 'wiim',
            onPick: (_) {},
            onRescan: () {},
          ),
        ),
        ipad,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 箱の左端から点までが dotInset。ここが変わると配置の逆算が崩れる。
    final box = tester.getRect(find.byType(DevicePopover));
    final dot = tester.getRect(find.byType(StatusDot).first);
    expect(dot.left - box.left, DevicePopover.dotInset);
  });

  // ステータスバー（時刻・バッテリー）の帯を左右で塗り分けるために、レールは
  // 画面の天から敷いて、中身だけ topInset で下げている。SafeArea をレイアウトの
  // 外に戻すとレールの面が帯の手前で切れて、帯が背景グラデ 1 色に戻る。
  testWidgets('iPad: 帯のぶんは面ではなく中身だけが下がる', (tester) async {
    const inset = 24.0;
    tester.view.physicalSize = ipad;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    /// レール（幅 452 の箱）と、その中の進捗バーの位置。
    Future<(Rect, Rect)> layoutWith(double topInset) async {
      final controller = await buildController(tester, playing: true);
      await tester.pumpWidget(
        wrap(
          TabletLayout(
            controller: controller,
            newReleases: _idleReleases(),
            onPlayNow: (_) {},
            onPlayPlaylist: (_) {},
            onPlayRelease: (_) {},
            attribution: const SizedBox.shrink(),
            topInset: topInset,
          ),
          ipad,
        ),
      );
      await tester.pump();
      return (
        tester.getRect(
          find.byWidgetPredicate((w) => w is SizedBox && w.width == 452),
        ),
        tester.getRect(find.byType(ProgressRow)),
      );
    }

    final (railFlush, progressFlush) = await layoutWith(0);
    final (rail, progress) = await layoutWith(inset);

    // 面は帯を含めて画面いっぱい。上端が下がると帯が塗れない。
    expect(railFlush.top, 0);
    expect(rail, railFlush);
    // 中身だけ帯のぶん下がる（余白の実値には依存させない）。
    expect(progress.top - progressFlush.top, inset);
  });

  testWidgets('停止中(204)は「停止中」の状態表示になる', (tester) async {
    tester.view.physicalSize = iphone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = await buildController(tester, playing: false);
    expect(controller.isStopped, isTrue);
    expect(controller.showStoppedBanner, isTrue);
    expect(controller.statusLabel, 'Stopped · 204 NO CONTENT');

    await tester.pumpWidget(
      wrap(
        PhoneLayout(
          controller: controller,
          newReleases: _idleReleases(),
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          onPlayRelease: (_) {},
          attribution: const SizedBox.shrink(),
          topInset: 72,
        ),
        iphone,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('キューは空です'), findsOneWidget);
  });
}
