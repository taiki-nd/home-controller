import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/ma_models.dart';
import 'package:spotify_remote/services/music_assistant_api.dart';
import 'package:spotify_remote/state/ma_controller.dart';

import 'ma_support.dart';

/// 繋がった [MaController] と、その裏のソケットを返す。
///
/// `start()` は握手 → `players/all` → `player_queues/all` →
/// `player_queues/items` の順に投げるので、片方ずつ応答してやる。
Future<(MaController, FakeMaSocket)> started({
  List<Map<String, Object?>>? players,
  List<Map<String, Object?>>? queues,
  List<Map<String, Object?>>? items,
}) async {
  final socket = FakeMaSocket();
  final controller = MaController(
    credentials: FakeMaCredentials(testMaConnection),
    open: (connection) =>
        MaSession.connect(connection, opener: (_) async => socket),
  );
  final pending = controller.start();

  await pumpEventQueue();
  socket.hello();
  await pumpEventQueue();
  socket.reply('auth', result: {'authenticated': true});
  await pumpEventQueue();
  socket.reply(
    'players/all',
    result: players ?? [playerJson('wiim-1', 'リビング')],
  );
  await pumpEventQueue();
  socket.reply(
    'player_queues/all',
    result: queues ?? [queueJson('wiim-1')],
  );
  await pumpEventQueue();
  socket.reply('player_queues/items', result: items ?? const []);
  await pending;
  await pumpEventQueue();
  return (controller, socket);
}

void main() {
  test('繋がったらプレイヤーとキューが揃う', () async {
    final (controller, _) = await started(
      queues: [queueJson('wiim-1', state: 'playing', items: 3)],
    );
    addTearDown(controller.dispose);

    expect(controller.status, MaStatus.connected);
    expect(controller.players.map((p) => p.name), ['リビング']);
    expect(controller.selectedPlayer?.playerId, 'wiim-1');
    expect(controller.isPlaying, isTrue);
  });

  test('何も選ばれていなければ、鳴っているプレイヤーを拾う', () async {
    final (controller, _) = await started(
      players: [
        playerJson('wiim-1', 'あ'),
        playerJson('wiim-2', 'い'),
      ],
      queues: [
        queueJson('wiim-1'),
        queueJson('wiim-2', state: 'playing'),
      ],
    );
    addTearDown(controller.dispose);

    // 名前順の先頭は wiim-1 だが、鳴っているほうを選ぶ。
    expect(controller.selectedPlayer?.playerId, 'wiim-2');
  });

  test('queue_time_updated は progressTick だけを叩く（毎秒の全画面再描画を避ける）',
      () async {
    final (controller, socket) = await started(
      queues: [queueJson('wiim-1', state: 'playing')],
    );
    addTearDown(controller.dispose);

    var rebuilds = 0;
    var ticks = 0;
    controller.addListener(() => rebuilds++);
    controller.progressTick.addListener(() => ticks++);

    socket.pushEvent('queue_time_updated', objectId: 'wiim-1', data: 42.0);
    await pumpEventQueue();

    expect(ticks, 1);
    expect(rebuilds, 0);
    expect(controller.position.inSeconds, greaterThanOrEqualTo(42));
  });

  test('queue_updated で状態が入れ替わる', () async {
    final (controller, socket) = await started();
    addTearDown(controller.dispose);

    expect(controller.isPlaying, isFalse);
    socket.pushEvent(
      'queue_updated',
      objectId: 'wiim-1',
      data: queueJson(
        'wiim-1',
        state: 'playing',
        items: 1,
        currentIndex: 0,
        currentItem: queueItemJson('a', 'Kind of Blue', artist: 'Miles Davis'),
      ),
    );
    await pumpEventQueue();

    expect(controller.isPlaying, isTrue);
    expect(controller.currentItem?.artist, 'Miles Davis');
  });

  test('キューは「これから」だけ出す（鳴っている曲より後ろ）', () async {
    final (controller, socket) = await started(
      queues: [queueJson('wiim-1', items: 3, currentIndex: 1)],
      items: [
        queueItemJson('a', 'One', index: 0),
        queueItemJson('b', 'Two', index: 1),
        queueItemJson('c', 'Three', index: 2),
      ],
    );
    addTearDown(controller.dispose);
    // start() の直後は current_index を持つキューが届いている。
    await pumpEventQueue();
    expect(controller.upNext.map((i) => i.name), ['Three']);
    expect(socket.closed, isFalse);
  });

  test('操作はプレイヤーではなくキューに送る', () async {
    final (controller, socket) = await started();
    addTearDown(controller.dispose);

    final pending = controller.togglePlayPause();
    await pumpEventQueue();
    final frame = socket.lastOf('player_queues/play_pause')!;
    expect((frame['args'] as Map)['queue_id'], 'wiim-1');
    socket.reply('player_queues/play_pause');
    await pending;
  });

  test('キューに積むとトーストを出す', () async {
    final (controller, socket) = await started();
    addTearDown(controller.dispose);

    const item = MaMediaItem(
      uri: 'qobuz://track/42',
      name: 'So What',
      mediaType: 'track',
    );
    final pending = controller.enqueue(item);
    await pumpEventQueue();
    socket.reply('player_queues/play_media');
    await pending;

    expect(controller.toast, 'So What をキューに追加');
  });

  test('トークンを拒否されたら再接続せず設定画面へ倒す', () async {
    final socket = FakeMaSocket();
    final controller = MaController(
      credentials: FakeMaCredentials(testMaConnection),
      open: (connection) =>
          MaSession.connect(connection, opener: (_) async => socket),
    );
    addTearDown(controller.dispose);

    final pending = controller.start();
    await pumpEventQueue();
    socket.hello();
    await pumpEventQueue();
    socket.fail('auth', 21, 'Invalid token');
    await pending;

    expect(controller.status, MaStatus.authFailed);
    expect(controller.needsSetup, isTrue);
  });

  test('接続先が保存されていなければ設定画面から始める', () async {
    final controller = MaController(
      credentials: FakeMaCredentials(),
      open: (_) async => throw StateError('繋ぎに行ってはいけない'),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.status, MaStatus.needsSetup);
  });
}
