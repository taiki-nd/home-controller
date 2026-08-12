import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/ma_models.dart';
import 'package:spotify_remote/services/ma_credentials.dart';
import 'package:spotify_remote/services/music_assistant_api.dart';

import 'ma_support.dart';

/// サーバー情報 → `auth` → 結果まで通して session を返す。
Future<(MaSession, FakeMaSocket)> connect({
  int schemaVersion = 33,
  MaConnection? connection,
}) async {
  final socket = FakeMaSocket();
  final pending = MaSession.connect(
    connection ?? testMaConnection,
    opener: (_) async => socket,
  );
  await pumpEventQueue();
  socket.hello(schemaVersion: schemaVersion);
  await pumpEventQueue();
  if (schemaVersion >= 28) {
    socket.reply('auth', result: {'authenticated': true});
  }
  return (await pending, socket);
}

void main() {
  group('MaSession の握手', () {
    test('サーバー情報を受けてからトークンを送る', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final auth = socket.lastOf('auth');
      expect(auth, isNotNull);
      expect((auth!['args'] as Map)['token'], 'ma-token');
      // message_id は文字列（HA は int）。
      expect(auth['message_id'], isA<String>());
      expect(session.serverInfo?.schemaVersion, 33);
      expect(session.isClosed, isFalse);
    });

    test('認証のいらない世代（schema 27）では auth を送らない', () async {
      final (session, socket) = await connect(
        schemaVersion: 27,
        connection: MaConnection(
          baseUrl: Uri.parse('http://ma.local:8095'),
          token: '',
        ),
      );
      addTearDown(session.close);

      expect(socket.lastOf('auth'), isNull);
    });

    test('トークンが要る世代で空トークンなら、繋ぐ前に認証エラーにする', () async {
      final socket = FakeMaSocket();
      final pending = MaSession.connect(
        MaConnection(baseUrl: Uri.parse('http://ma.local:8095'), token: ''),
        opener: (_) async => socket,
      );
      await pumpEventQueue();
      socket.hello();

      await expectLater(pending, throwsA(isA<MaAuthException>()));
    });

    test('error_code 21 はトークンの問題として区別する（再接続しても直らない）', () async {
      final socket = FakeMaSocket();
      final pending = MaSession.connect(
        testMaConnection,
        opener: (_) async => socket,
      );
      await pumpEventQueue();
      socket.hello();
      await pumpEventQueue();
      socket.fail('auth', 21, 'Invalid token');

      await expectLater(pending, throwsA(isA<MaAuthException>()));
    });

    test('認証以外の error_code はただの失敗にする', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.fetchPlayers();
      await pumpEventQueue();
      socket.fail('players/all', 10, 'Player unavailable');

      await expectLater(
        pending,
        throwsA(
          isA<MaException>()
              .having((e) => e.message, 'message', 'Player unavailable')
              .having((e) => e, 'not auth', isNot(isA<MaAuthException>())),
        ),
      );
    });
  });

  group('MaSession のコマンド', () {
    test('players/all を MaPlayer に読み替える', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.fetchPlayers();
      await pumpEventQueue();
      socket.reply(
        'players/all',
        result: [
          playerJson('wiim-1', 'リビング'),
          playerJson('wiim-2', '寝室', available: false),
        ],
      );

      final players = await pending;
      expect(players, hasLength(2));
      expect(players.first.name, 'リビング');
      expect(players.first.isSelectable, isTrue);
      expect(players.last.isSelectable, isFalse);
    });

    test('partial で分割された result を繋ぎ直す', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.fetchQueueItems('wiim-1');
      await pumpEventQueue();
      socket.reply(
        'player_queues/items',
        result: [queueItemJson('a', 'One', index: 0)],
        partial: true,
      );
      await pumpEventQueue();
      socket.reply(
        'player_queues/items',
        result: [queueItemJson('b', 'Two', index: 1)],
      );

      final items = await pending;
      expect(items.map((i) => i.name), ['One', 'Two']);
    });

    test('play_media は option をそのまま送る', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.playMedia(
        'wiim-1',
        'qobuz://track/42',
        option: MaQueueOption.next,
      );
      await pumpEventQueue();
      final args =
          socket.lastOf('player_queues/play_media')!['args'] as Map;
      expect(args['queue_id'], 'wiim-1');
      expect(args['media'], 'qobuz://track/42');
      expect(args['option'], 'next');

      socket.reply('player_queues/play_media');
      await pending;
    });

    test('購読コマンドを送らずにイベントを受け取る', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final events = <MaEvent>[];
      session.events.listen(events.add);
      socket.pushEvent('queue_time_updated', objectId: 'wiim-1', data: 12.5);
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.first.type, 'queue_time_updated');
      expect(events.first.objectId, 'wiim-1');
      expect(events.first.data, 12.5);
      // HA の subscribe_events に当たるものは存在しない。
      expect(
        socket.sent.map((f) => f['command']),
        everyElement(isNot(contains('subscribe'))),
      );
    });

    test('切断したら待っている呼び出しを落とす', () async {
      final (session, socket) = await connect();

      final pending = session.fetchQueues();
      await pumpEventQueue();
      await socket.close();

      await expectLater(pending, throwsA(isA<MaException>()));
      expect(session.isClosed, isTrue);
    });
  });

  group('MaConnection', () {
    test('ポート未指定なら 8095 を補う', () {
      expect(
        MaConnection.parseBaseUrl('192.168.1.10'),
        Uri.parse('http://192.168.1.10:8095'),
      );
    });

    test('https のポートは書き換えない（リバースプロキシ越しの 443）', () {
      expect(
        MaConnection.parseBaseUrl('https://ma.example.com'),
        Uri.parse('https://ma.example.com'),
      );
    });

    test('websocketUrl は /ws', () {
      expect(
        testMaConnection.websocketUrl.toString(),
        'ws://ma.local:8095/ws',
      );
    });
  });
}
