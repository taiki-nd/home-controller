import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/ha_models.dart';
import 'package:spotify_remote/services/home_assistant_api.dart';
import 'package:spotify_remote/state/home_controller.dart';

import 'ha_support.dart';

/// 送られたコマンドに自動で応じるソケット。
///
/// 単一購読の [StreamController] は listen 前の add をバッファするので、
/// コンストラクタで `auth_required` を流しておいてよい。
class ScriptedSocket extends FakeHaSocket {
  ScriptedSocket({
    this.states = const [],
    this.areas = const [],
    this.devices = const [],
    this.entities = const [],
    this.callServiceError,
    this.answerCallService = true,
    this.authInvalid = false,
  }) {
    emit({'type': 'auth_required'});
  }

  final List<Map<String, Object?>> states;
  final List<Map<String, Object?>> areas;
  final List<Map<String, Object?>> devices;
  final List<Map<String, Object?>> entities;

  /// null 以外なら call_service をこのメッセージで失敗させる。
  final String? callServiceError;

  /// false なら call_service に一切応じない（HA が固まった状況）。
  final bool answerCallService;

  /// true なら `auth` に `auth_invalid` を返す。
  final bool authInvalid;

  @override
  void send(String data) {
    super.send(data);
    final frame = sent.last;
    final id = frame['id'] as int?;
    scheduleMicrotask(() {
      switch (frame['type']) {
        case 'auth':
          emit(
            authInvalid
                ? {'type': 'auth_invalid', 'message': 'Invalid access token'}
                : {'type': 'auth_ok'},
          );
        case 'get_states':
          reply(id!, result: states);
        case 'subscribe_events':
          reply(id!);
        case 'config/area_registry/list':
          reply(id!, result: areas);
        case 'config/device_registry/list':
          reply(id!, result: devices);
        case 'config/entity_registry/list':
          reply(id!, result: entities);
        case 'call_service':
          if (!answerCallService) return;
          if (callServiceError != null) {
            emit({
              'id': id,
              'type': 'result',
              'success': false,
              'error': {'message': callServiceError},
            });
          } else {
            reply(id!);
          }
        case 'ping':
          emit({'id': id, 'type': 'pong'});
      }
    });
  }
}

HomeController controllerFor(ScriptedSocket socket) => HomeController(
  credentials: FakeHaCredentials(testConnection),
  open: (connection) =>
      HaSession.connect(connection, opener: (_) async => socket),
);

void main() {
  test('接続すると get_states の中身が並ぶ', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('light.living', 'on', attributes: {'friendly_name': '天井'}),
        stateJson('switch.fan', 'off', attributes: {'friendly_name': '換気'}),
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.status, HaStatus.connected);
    expect(controller.entities.map((e) => e.name), containsAll(['天井', '換気']));
    expect(controller.onCount, 1);
  });

  test('ラベルが付いているエンティティがあれば、それだけに絞る', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('light.living', 'on'),
        stateJson('light.garage', 'on'),
      ],
      entities: [
        {
          'entity_id': 'light.living',
          'labels': [HomeController.labelId],
        },
        {'entity_id': 'light.garage', 'labels': <String>[]},
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);

    await controller.start();
    expect(
      controller.entities.map((e) => e.entityId),
      ['light.living'],
    );
  });

  test('ラベル未設定ならセンサーは温湿度だけに絞る（バッテリー残量で埋めない）', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('sensor.temp', '22.4', attributes: {
          'device_class': 'temperature',
          'unit_of_measurement': '°C',
        }),
        stateJson('sensor.battery', '87', attributes: {
          'device_class': 'battery',
        }),
        stateJson('light.living', 'off'),
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);

    await controller.start();
    final ids = controller.entities.map((e) => e.entityId).toList();
    expect(ids, contains('sensor.temp'));
    expect(ids, isNot(contains('sensor.battery')));
    expect(controller.readouts.single.readout, '22.4°C');
  });

  test('部屋はデバイス経由の area でも分かれ、area 無しは最後にまとまる', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('light.living', 'on'),
        stateJson('light.loose', 'off'),
      ],
      areas: [
        {'area_id': 'living', 'name': 'リビング'},
      ],
      devices: [
        {'id': 'dev1', 'area_id': 'living'},
      ],
      entities: [
        {'entity_id': 'light.living', 'device_id': 'dev1'},
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.rooms.map((r) => r.name), ['リビング', 'その他']);
    expect(controller.selectedRoomId, 'living');
    expect(controller.tiles.single.entityId, 'light.living');
    expect(controller.roomHasOn('living'), isTrue);

    controller.selectRoom(HaRoom.unassignedId);
    expect(controller.tiles.single.entityId, 'light.loose');
  });

  test('タップした瞬間に反転し、state_changed で確定する', () async {
    final socket = ScriptedSocket(states: [stateJson('light.living', 'off')]);
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);
    await controller.start();

    final light = controller.entities.single;
    final pending = controller.toggle(light);

    // まだ HA からは何も返っていないが、UI 上はもう点いている。
    expect(controller.entities.single.isOn, isTrue);
    await pending;
    expect(socket.lastOf('call_service')!['service'], 'turn_on');

    // 本物が届いたら楽観更新は役目を終える。
    socket.pushState('light.living', 'on', attributes: {'brightness': 255});
    await pumpEventQueue();
    expect(controller.entities.single.brightnessPercent, 100);
  });

  test('call_service が失敗したら元に戻してエラーを出す', () async {
    final socket = ScriptedSocket(
      states: [stateJson('light.living', 'off')],
      callServiceError: 'not found',
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);
    await controller.start();

    await controller.toggle(controller.entities.single);

    expect(controller.entities.single.isOn, isFalse);
    expect(controller.errorBanner, contains('not found'));
  });

  test('応答が来なければ 5 秒で元に戻す', () {
    fakeAsync((async) {
      final socket = ScriptedSocket(
        states: [stateJson('light.living', 'off')],
        answerCallService: false,
      );
      final controller = controllerFor(socket);
      controller.start();
      async.flushMicrotasks();

      controller.toggle(controller.entities.single);
      async.flushMicrotasks();
      expect(controller.entities.single.isOn, isTrue);

      async.elapse(const Duration(seconds: 6));
      expect(controller.entities.single.isOn, isFalse);
      expect(controller.errorBanner, contains('応答しませんでした'));

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('エアコンは turn_on ではなく set_hvac_mode で点け直す', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('climate.living', 'off', attributes: {
          'hvac_modes': ['off', 'cool', 'heat', 'heat_cool'],
          'temperature': 26.0,
          'min_temp': 16.0,
          'max_temp': 30.0,
          'target_temp_step': 0.5,
        }),
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);
    await controller.start();

    await controller.toggle(controller.entities.single);
    final call = socket.lastOf('call_service')!;
    expect(call['service'], 'set_hvac_mode');
    expect(call['service_data'], {'hvac_mode': 'heat_cool'});
  });

  test('温度は刻みぶん動き、上限で止まる', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('climate.living', 'cool', attributes: {
          'temperature': 29.5,
          'min_temp': 16.0,
          'max_temp': 30.0,
          'target_temp_step': 0.5,
        }),
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);
    await controller.start();

    await controller.nudgeTemperature(controller.entities.single, 1);
    expect(
      socket.lastOf('call_service')!['service_data'],
      {'temperature': 30.0},
    );

    // 上限に張り付いたら、それ以上のコマンドは投げない。
    final before = socket.sent.length;
    await controller.nudgeTemperature(controller.entities.single, 1);
    expect(socket.sent.length, before);
  });

  test('明るさ 0% は turn_off として送る', () async {
    final socket = ScriptedSocket(
      states: [
        stateJson('light.living', 'on', attributes: {
          'supported_color_modes': ['brightness'],
          'brightness': 255,
        }),
      ],
    );
    final controller = controllerFor(socket);
    addTearDown(controller.dispose);
    await controller.start();

    await controller.setBrightnessPercent(controller.entities.single, 0);
    expect(socket.lastOf('call_service')!['service'], 'turn_off');

    await controller.setBrightnessPercent(controller.entities.single, 40);
    final call = socket.lastOf('call_service')!;
    expect(call['service'], 'turn_on');
    expect(call['service_data'], {'brightness_pct': 40});
  });

  test('トークンが拒否されたら設定画面へ倒す（繋ぎ直しても直らないため）', () async {
    final controller = controllerFor(ScriptedSocket(authInvalid: true));
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.status, HaStatus.authFailed);
    expect(controller.needsSetup, isTrue);
  });

  test('通信都合で繋がらないときは設定画面へ倒さず、時間をおいてやり直す', () {
    fakeAsync((async) {
      var attempts = 0;
      final controller = HomeController(
        credentials: FakeHaCredentials(testConnection),
        open: (_) {
          attempts++;
          throw HaException('圏外');
        },
      );
      controller.start();
      async.flushMicrotasks();

      expect(attempts, 1);
      expect(controller.status, HaStatus.offline);
      // トークンの問題ではないので、設定画面には飛ばさない。
      expect(controller.needsSetup, isFalse);

      // バックオフしながら自動で繋ぎ直す。
      async.elapse(const Duration(seconds: 3));
      expect(attempts, 2);
      async.elapse(const Duration(seconds: 5));
      expect(attempts, 3);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('接続先が無ければ設定画面を出す', () async {
    final controller = HomeController(credentials: FakeHaCredentials());
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.status, HaStatus.needsSetup);
    expect(controller.needsSetup, isTrue);
  });
}
