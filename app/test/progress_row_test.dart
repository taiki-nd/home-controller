import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/player_controller.dart';
import 'package:spotify_remote/ui/widgets/transport.dart';

/// 4:04 の曲を 1:02 まで再生した状態（= 進捗 25.4%）。
class _FakeApi extends SpotifyApi {
  _FakeApi() : super(AuthService());

  @override
  Future<PlaybackState> playbackState() async => PlaybackState(
    isPlaying: true,
    progressMs: 62000,
    shuffleState: false,
    hasContent: true,
    track: const Track(
      id: 'cur',
      uri: 'spotify:track:cur',
      name: 'Midnight City',
      artists: 'M83',
      albumName: 'Album',
      durationMs: 244000,
    ),
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

  @override
  Future<QueueSnapshot> queue() async => const QueueSnapshot(upcoming: []);

  @override
  Future<List<SpotifyDevice>> devices() async => const [];

  @override
  Future<List<PlaylistSummary>> playlists({int limit = 50}) async => const [];
}

void main() {
  const barWidth = 340.0;
  const barHeight = 6.0;

  /// 塗り（白）の矩形。背景は白 18% なので色で見分けられる。
  Rect fillRect(WidgetTester tester) => tester.getRect(
    find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.white),
  );

  testWidgets('進捗バーの塗りが再生位置ぶんの幅と高さで出る', (tester) async {
    final controller = PlayerController(_FakeApi());
    addTearDown(controller.dispose);
    await controller.start();
    controller.setForeground(false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: barWidth,
              child: ProgressRow(controller: controller, barHeight: barHeight),
            ),
          ),
        ),
      ),
    );
    // 補間が終わるまで進める（ティック間隔と同じ 500ms）。
    await tester.pump(const Duration(milliseconds: 600));

    expect(controller.progressFraction, closeTo(0.254, 0.01));

    final fill = fillRect(tester);
    // 高さが 0 だと「グレーのまま」に見える。ここが本題。
    expect(fill.height, barHeight);
    expect(fill.width, closeTo(barWidth * controller.progressFraction, 1));
    // 塗りは左端から伸びる（中央からではない）。
    expect(fill.left, closeTo((800 - barWidth) / 2, 0.5));
  });
}
