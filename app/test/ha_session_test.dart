import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/ha_models.dart';
import 'package:spotify_remote/services/ha_credentials.dart';
import 'package:spotify_remote/services/home_assistant_api.dart';

import 'ha_support.dart';

/// `auth_required` → `auth` → `auth_ok` まで通して session を返す。
Future<(HaSession, FakeHaSocket)> connect() async {
  final socket = FakeHaSocket();
  final pending = HaSession.connect(
    testConnection,
    opener: (_) async => socket,
  );
  await pumpEventQueue();
  socket.emit({'type': 'auth_required', 'ha_version': '2026.6.0'});
  await pumpEventQueue();
  socket.emit({'type': 'auth_ok'});
  return (await pending, socket);
}

void main() {
  group('HaSession', () {
    test('auth_required を待ってからトークンを送り、auth_ok で開通する', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final auth = socket.lastOf('auth');
      expect(auth, isNotNull);
      expect(auth!['access_token'], 'token');
      expect(session.isClosed, isFalse);
    });

    test('auth_invalid はトークンの問題として区別する（再接続しても直らない）', () async {
      final socket = FakeHaSocket();
      final pending = HaSession.connect(
        testConnection,
        opener: (_) async => socket,
      );
      await pumpEventQueue();
      socket.emit({'type': 'auth_required'});
      await pumpEventQueue();
      socket.emit({'type': 'auth_invalid', 'message': 'Invalid access token'});

      await expectLater(pending, throwsA(isA<HaAuthException>()));
    });

    test('get_states を HaEntity に読み替える', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.fetchStates();
      await pumpEventQueue();
      final request = socket.lastOf('get_states')!;
      socket.reply(request['id'] as int, result: [
        stateJson('light.living', 'on', attributes: {
          'friendly_name': 'リビング',
          'brightness': 128,
        }),
      ]);

      final states = await pending;
      expect(states, hasLength(1));
      expect(states.first.name, 'リビング');
      expect(states.first.isOn, isTrue);
      expect(states.first.brightnessPercent, 50);
    });

    test('state_changed が stateChanges に流れる', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final next = session.stateChanges.first;
      socket.pushState('switch.fan', 'off');

      final entity = await next;
      expect(entity.entityId, 'switch.fan');
      expect(entity.isOn, isFalse);
    });

    test('call_service は target.entity_id と service_data を組み立てる', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      unawaited(
        session.callService(
          'light',
          'turn_on',
          entityId: 'light.living',
          data: {'brightness_pct': 40},
        ),
      );
      await pumpEventQueue();

      final frame = socket.lastOf('call_service')!;
      expect(frame['domain'], 'light');
      expect(frame['service'], 'turn_on');
      expect(frame['target'], {'entity_id': 'light.living'});
      expect(frame['service_data'], {'brightness_pct': 40});
    });

    test('レジストリはデバイス経由の area も引き継ぐ', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.fetchRegistry();
      await pumpEventQueue();
      socket.reply(
        socket.lastOf('config/area_registry/list')!['id'] as int,
        result: [
          {'area_id': 'living', 'name': 'リビング'},
        ],
      );
      await pumpEventQueue();
      socket.reply(
        socket.lastOf('config/device_registry/list')!['id'] as int,
        result: [
          {'id': 'dev1', 'area_id': 'living'},
        ],
      );
      await pumpEventQueue();
      socket.reply(
        socket.lastOf('config/entity_registry/list')!['id'] as int,
        result: [
          // エンティティ自身に area は無く、デバイス側にだけある。
          {
            'entity_id': 'light.living',
            'device_id': 'dev1',
            'labels': ['home-ctl'],
          },
        ],
      );

      final registry = await pending;
      expect(registry.areaOf('light.living'), 'living');
      expect(registry.areaNames['living'], 'リビング');
      expect(registry.hasLabel('light.living', 'home-ctl'), isTrue);
    });

    test('レジストリが引けない（管理者でない）ときは空で返して操作は続ける', () async {
      final (session, socket) = await connect();
      addTearDown(session.close);

      final pending = session.fetchRegistry();
      await pumpEventQueue();
      socket.emit({
        'id': socket.lastOf('config/area_registry/list')!['id'],
        'type': 'result',
        'success': false,
        'error': {'code': 'unauthorized', 'message': 'Unauthorized'},
      });

      expect(await pending, HaRegistry.empty);
      expect(session.isClosed, isFalse);
    });

    test('切断は待っている呼び出しを落として done を完了させる', () async {
      final (session, socket) = await connect();

      final pending = session.fetchStates();
      await socket.close();

      await expectLater(pending, throwsA(isA<HaException>()));
      await session.done;
      expect(session.isClosed, isTrue);
    });
  });

  group('HaConnection.parseBaseUrl', () {
    test('scheme 無しは http、ポート未指定は 8123 を補う', () {
      final uri = HaConnection.parseBaseUrl('192.168.1.10');
      expect(uri.toString(), 'http://192.168.1.10:8123');
    });

    test('末尾スラッシュやパスは落とす', () {
      final uri = HaConnection.parseBaseUrl('http://ha.local:8123/lovelace/0');
      expect(uri.toString(), 'http://ha.local:8123');
    });

    test('https は既定ポートを 8123 に書き換えない（プロキシ越しを壊さない）', () {
      final uri = HaConnection.parseBaseUrl('https://ha.example.com');
      expect(uri.toString(), 'https://ha.example.com');
    });

    test('空・不正は null', () {
      expect(HaConnection.parseBaseUrl(''), isNull);
      expect(HaConnection.parseBaseUrl('ftp://ha.local'), isNull);
    });
  });

  group('HaEntity', () {
    test('climate は off 以外がすべて運転中', () {
      final entity = HaEntity.fromJson(stateJson('climate.living', 'cool'));
      expect(entity.isOn, isTrue);
      expect(
        HaEntity.fromJson(stateJson('climate.living', 'off')).isOn,
        isFalse,
      );
    });

    test('unavailable は OFF と区別する', () {
      final entity = HaEntity.fromJson(stateJson('light.x', 'unavailable'));
      expect(entity.isUnavailable, isTrue);
      expect(entity.isOn, isFalse);
    });

    test('点け直すモードは heat_cool / auto を優先する', () {
      final entity = HaEntity.fromJson(
        stateJson('climate.x', 'off', attributes: {
          'hvac_modes': ['off', 'heat', 'cool', 'heat_cool'],
        }),
      );
      expect(entity.preferredHvacMode, 'heat_cool');
    });

    test('onoff だけの照明にはスライダを出さない', () {
      final dimmable = HaEntity.fromJson(
        stateJson('light.a', 'on', attributes: {
          'supported_color_modes': ['brightness'],
        }),
      );
      final plain = HaEntity.fromJson(
        stateJson('light.b', 'on', attributes: {
          'supported_color_modes': ['onoff'],
        }),
      );
      expect(dimmable.supportsBrightness, isTrue);
      expect(plain.supportsBrightness, isFalse);
    });

    test('MVP で出さないドメインは unsupported', () {
      expect(tileKindFor('light'), HaTileKind.toggle);
      expect(tileKindFor('scene'), HaTileKind.press);
      expect(tileKindFor('climate'), HaTileKind.climate);
      expect(tileKindFor('sensor'), HaTileKind.readout);
      // 誤タップで玄関が開くので、確認ステップを設計するまで出さない。
      expect(tileKindFor('lock'), HaTileKind.unsupported);
      // music 側と役割が混ざるので後回し。
      expect(tileKindFor('media_player'), HaTileKind.unsupported);
    });
  });
}

/// `unawaited` を test から使うための最小実装（dart:async を import しない）。
void unawaited(Future<void> future) {
  future.catchError((Object _) {});
}
