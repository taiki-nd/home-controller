import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/player_controller.dart';

/// 曲送りは Spotify 側の反映が数百 ms 遅れる。その間 `GET /me/player` は
/// 送る前の曲を返してくるので、素直に映すと「前の曲に戻ってから次の曲」に
/// 見える。それが起きないことをここで固定する。
class FakeSkipApi extends SpotifyApi {
  FakeSkipApi() : super(AuthService());

  static Track track(String id) => Track(
    id: id,
    uri: 'spotify:track:$id',
    name: id,
    artists: 'Artist',
    albumName: 'Album',
    durationMs: 200000,
  );

  /// Spotify が「いま鳴っている」と言う曲。テストが明示的に進める。
  String current = 'a';
  List<String> upcoming = ['b', 'c'];

  int nextCalls = 0;
  int previousCalls = 0;
  bool failCommands = false;

  @override
  Future<PlaybackState> playbackState() async => PlaybackState(
    isPlaying: true,
    progressMs: 1000,
    shuffleState: false,
    hasContent: true,
    track: track(current),
  );

  @override
  Future<QueueSnapshot> queue() async =>
      QueueSnapshot(upcoming: upcoming.map(track).toList());

  @override
  Future<void> next() async {
    if (failCommands) throw SpotifyApiException('だめでした', statusCode: 500);
    nextCalls++;
  }

  @override
  Future<void> previous() async {
    if (failCommands) throw SpotifyApiException('だめでした', statusCode: 500);
    previousCalls++;
  }

  @override
  Future<List<SpotifyDevice>> devices() async => const [];

  @override
  Future<List<PlaylistSummary>> playlists({int limit = 50}) async => const [];

  @override
  Duration? get rateLimitCooldown => null;
}

void withController(
  void Function(FakeAsync async, FakeSkipApi api, PlayerController controller)
  body,
) {
  fakeAsync((async) {
    final start = DateTime(2026, 1, 1);
    final api = FakeSkipApi();
    final controller = PlayerController(
      api,
      now: () => start.add(async.elapsed),
    );
    controller.start();
    async.flushMicrotasks();
    body(async, api, controller);
    controller.dispose();
  });
}

void main() {
  test('次へ送ると返事を待たずにキューの先頭が出る', () {
    withController((async, api, controller) {
      expect(controller.currentTrack?.id, 'a');

      controller.skipNext();
      async.flushMicrotasks();

      // API の往復も反映も待たずに切り替わっている。
      expect(controller.currentTrack?.id, 'b');
      expect(controller.nextTrack?.id, 'c');
      expect(api.nextCalls, 1);
    });
  });

  test('反映が遅れて古い曲が返ってきても戻らない', () {
    withController((async, api, controller) {
      final seen = <String?>[];
      controller.addListener(() => seen.add(controller.currentTrack?.id));

      controller.skipNext();
      async.flushMicrotasks();

      // Spotify はまだ送る前の曲を返す。1 秒ぶん叩かせても 'a' には戻らない。
      async.elapse(const Duration(seconds: 1));
      expect(controller.currentTrack?.id, 'b');

      // 追いついた。
      api
        ..current = 'b'
        ..upcoming = ['c'];
      async.elapse(const Duration(seconds: 1));
      expect(controller.currentTrack?.id, 'b');

      // 一度も 'a' を経由していない＝ちらつかない。
      expect(seen.contains('a'), isFalse);
    });
  });

  test('待っても追いつかなければ真の状態に戻る（送りが効いていない）', () {
    withController((async, api, controller) {
      controller.skipNext();
      async.flushMicrotasks();
      expect(controller.currentTrack?.id, 'b');

      // 5 秒待っても Spotify は 'a' のまま。諦めて事実に従う。
      async.elapse(const Duration(seconds: 8));
      expect(controller.currentTrack?.id, 'a');
    });
  });

  test('送りに失敗したら元の曲に戻してバナーを出す', () {
    withController((async, api, controller) {
      api.failCommands = true;

      controller.skipNext();
      async.flushMicrotasks();

      expect(controller.currentTrack?.id, 'a');
      expect(controller.nextTrack?.id, 'b');
      expect(controller.errorBanner, isNotNull);
    });
  });

  test('前へ戻すと直前に鳴っていた曲が出る', () {
    withController((async, api, controller) {
      // 'a' → 'b' と鳴らして履歴を作る。
      controller.skipNext();
      async.flushMicrotasks();
      api
        ..current = 'b'
        ..upcoming = ['c'];
      async.elapse(const Duration(seconds: 1));
      expect(controller.currentTrack?.id, 'b');

      controller.skipPrevious();
      async.flushMicrotasks();
      expect(controller.currentTrack?.id, 'a');
      expect(controller.nextTrack?.id, 'b');
      expect(api.previousCalls, 1);
    });
  });
}
