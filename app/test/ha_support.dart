import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spotify_remote/services/ha_credentials.dart';
import 'package:spotify_remote/services/ha_socket.dart';

/// 本物の WebSocket を立てずにプロトコルを流すための口。
class FakeHaSocket implements HaSocket {
  final _incoming = StreamController<String>();

  /// クライアントが送ったフレーム（デコード済み）。
  final sent = <Map<String, dynamic>>[];

  bool closed = false;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) =>
      sent.add(jsonDecode(data) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// サーバー側から 1 フレーム流す。
  void emit(Map<String, Object?> message) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(message));
  }

  /// 直近に送られた、この type のフレーム。
  Map<String, dynamic>? lastOf(String type) {
    for (final frame in sent.reversed) {
      if (frame['type'] == type) return frame;
    }
    return null;
  }

  /// 指定 id のコマンドに成功で応じる。
  void reply(int id, {Object? result}) =>
      emit({'id': id, 'type': 'result', 'success': true, 'result': result});

  /// `state_changed` を 1 件流す。
  void pushState(
    String entityId,
    String state, {
    Map<String, Object?> attributes = const {},
  }) {
    emit({
      'type': 'event',
      'event': {
        'event_type': 'state_changed',
        'data': {
          'entity_id': entityId,
          'new_state': {
            'entity_id': entityId,
            'state': state,
            'attributes': attributes,
          },
        },
      },
    });
  }
}

/// Keychain を触らない [HaCredentials]。
class FakeHaCredentials extends HaCredentials {
  FakeHaCredentials([this.stored]);

  HaConnection? stored;

  @override
  Future<HaConnection?> load() async => stored;

  @override
  Future<void> save(HaConnection connection) async => stored = connection;

  @override
  Future<void> clear() async => stored = null;
}

final testConnection = HaConnection(
  baseUrl: Uri.parse('http://ha.local:8123'),
  token: 'token',
);

/// `get_states` の 1 要素。
Map<String, Object?> stateJson(
  String entityId,
  String state, {
  Map<String, Object?> attributes = const {},
}) => {
  'entity_id': entityId,
  'state': state,
  'attributes': attributes,
};

/// Keychain のプラグインを差し替える。
///
/// テスト環境ではハンドラが無く、`read` の Future が**完了しない**。
/// `AuthService.restore()` が返らず、music 側がローディングのまま止まるので、
/// music を出すウィジェットテストでは必ずこれを呼ぶ。
void mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
}
