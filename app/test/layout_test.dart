import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/player_controller.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/phone_layout.dart';
import 'package:spotify_remote/ui/tablet_layout.dart';

/// 実際に鳴っている状態を再現する差し替え API。
/// artworkUrl は null にしてある（テスト環境で Image.network を踏ませないため）。
class _FakeApi extends SpotifyApi {
  _FakeApi({required this.playing}) : super(AuthService());

  final bool playing;

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
      track: _track('cur', 'Midnight City', 'M83'),
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
}) async {
  final controller = PlayerController(_FakeApi(playing: playing));
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
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
          attribution: const SizedBox.shrink(),
        ),
        ipad,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Midnight City'), findsOneWidget);
    expect(find.text('M83'), findsOneWidget);
    // Up next カード + 残り 2 曲の見出し。
    expect(find.text('Get Lucky'), findsOneWidget);
    expect(find.text('3 TRACKS AHEAD'), findsOneWidget);
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
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
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
          onPlayNow: (_) {},
          onPlayPlaylist: (_) {},
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
