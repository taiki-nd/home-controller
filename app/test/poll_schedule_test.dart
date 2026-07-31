import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/player_controller.dart';

/// レート制限が主因だったので、「1 曲あたり何回叩くか」は目視ではなく
/// ここで固定しておく。
///
/// [SpotifyApi] を継承して読み取りだけ差し替える。_send を通らないので
/// AuthService は触られない（ゆえにプラグインも呼ばれない）。
class FakePlayer extends SpotifyApi {
  FakePlayer(this._elapsed) : super(AuthService());

  /// fake_async の経過時間。これを唯一の時計として再生位置を進める。
  final Duration Function() _elapsed;

  int playbackCalls = 0;
  int queueCalls = 0;

  static const trackLength = Duration(milliseconds: 200000); // 3分20秒

  /// true なら曲が終端で止まって次に進まない（バッファリングで延びた、
  /// あるいは外部から終端で一時停止された状況）。
  bool stallsAtEnd = false;
  bool playing = true;

  @override
  Future<PlaybackState> playbackState() async {
    playbackCalls++;
    if (!playing) return PlaybackState.stopped;
    final elapsedMs = _elapsed().inMilliseconds;
    final lengthMs = trackLength.inMilliseconds;
    // 終端で止まる場合は 1 曲目のまま位置が尺の直前で頭打ちになる。
    final progress = stallsAtEnd
        ? (elapsedMs < lengthMs ? elapsedMs : lengthMs - 1)
        : elapsedMs % lengthMs;
    final id = stallsAtEnd ? 'track0' : 'track${elapsedMs ~/ lengthMs}';
    return PlaybackState(
      isPlaying: true,
      progressMs: progress,
      shuffleState: false,
      hasContent: true,
      track: Track(
        id: id,
        uri: 'spotify:track:$id',
        name: id,
        artists: 'Artist',
        albumName: 'Album',
        durationMs: trackLength.inMilliseconds,
      ),
    );
  }

  @override
  Future<QueueSnapshot> queue() async {
    queueCalls++;
    return QueueSnapshot.empty;
  }

  // start() が呼ぶぶん。ここを塞がないと実物の _send に落ちて
  // AuthService がプラグインを触りにいく。
  @override
  Future<List<SpotifyDevice>> devices() async => const [];

  @override
  Future<List<PlaylistSummary>> playlists({int limit = 50}) async => const [];

  @override
  Duration? get rateLimitCooldown => null;
}

/// fake_async の中で「タイマーと同じ時計」を controller に渡す。
/// これをやらないと _nextPollDelay の残り時間計算が実時刻のままになり、
/// 曲の変わり目のスケジュールが検証できない。
void withFakePlayer(
  void Function(FakeAsync async, FakePlayer api, PlayerController controller)
  body,
) {
  fakeAsync((async) {
    final start = DateTime(2026, 1, 1);
    Duration elapsed() => async.elapsed;
    final api = FakePlayer(elapsed);
    final controller = PlayerController(api, now: () => start.add(elapsed()));
    controller.start();
    async.flushMicrotasks();
    body(async, api, controller);
    controller.dispose();
  });
}

void main() {
  test('再生中は 1 曲につき「変わり目 1 回 + 60 秒ハートビート」だけ', () {
    withFakePlayer((async, api, controller) {
      final atStart = api.playbackCalls;
      // ちょうど 1 曲ぶん（200 秒）流す。変わり目のポーリングは終了 +1.5s
      // なのでこの窓の外に落ちる。
      async.elapse(FakePlayer.trackLength);

      // 60 秒ハートビート 3 回だけ。旧実装（3 秒間隔）なら 66 回になる。
      expect(api.playbackCalls - atStart, 3);
      // 曲が変わっていないのでキューは起動時の 1 回のみ。
      expect(api.queueCalls, 1);
    });
  });

  test('曲の変わり目は予測どおり 1.5 秒後に拾う', () {
    withFakePlayer((async, api, controller) {
      expect(controller.currentTrack?.id, 'track0');

      // 曲の終わりの手前までは何も起きない。
      async.elapse(FakePlayer.trackLength - const Duration(seconds: 1));
      expect(controller.currentTrack?.id, 'track0');

      // 終了 + slack(1.5s) を過ぎたら次の曲になっている。
      async.elapse(const Duration(milliseconds: 2600));
      expect(controller.currentTrack?.id, 'track1');
    });
  });

  test('予測を過ぎても曲が変わらなければ追うが、間隔は伸びていく', () {
    withFakePlayer((async, api, controller) {
      api.stallsAtEnd = true;
      async.elapse(FakePlayer.trackLength);

      // 変わり目の直後: 1.5s → 3s → 6s と詰めて追う。
      final atBoundary = api.playbackCalls;
      async.elapse(const Duration(seconds: 15));
      final chased = api.playbackCalls - atBoundary;
      expect(chased, greaterThan(2));

      // ただし止まったままなら間隔が伸び、ハートビートで頭打ちになる。
      // 一律 1.5 秒で回し続けると、ここが 40 回になってしまう。
      final atStall = api.playbackCalls;
      async.elapse(const Duration(seconds: 60));
      expect(api.playbackCalls - atStall, lessThan(4));
    });
  });

  test('停止中はハートビートだけ', () {
    withFakePlayer((async, api, controller) {
      api.playing = false;
      final atStart = api.playbackCalls;
      async.elapse(const Duration(seconds: 200));

      // 60 秒ごとに 3 回。曲の終了予測では起きない。
      expect(api.playbackCalls - atStart, 3);
    });
  });
}
