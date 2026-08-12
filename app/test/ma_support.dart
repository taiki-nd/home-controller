import 'dart:async';
import 'dart:convert';

import 'package:spotify_remote/services/ma_credentials.dart';
import 'package:spotify_remote/services/ws_socket.dart';

/// 本物の WebSocket を立てずに MA のプロトコルを流すための口。
class FakeMaSocket implements AppSocket {
  final _incoming = StreamController<String>();

  /// クライアントが送ったフレーム（デコード済み）。
  final sent = <Map<String, dynamic>>[];

  bool closed = false;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) => sent.add(jsonDecode(data) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// サーバー側から 1 フレーム流す。
  void emit(Map<String, Object?> message) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(message));
  }

  /// 接続直後に向こうから飛んでくるサーバー情報。
  void hello({int schemaVersion = 33}) => emit({
    'server_id': 'test-server',
    'server_version': '2.10.0',
    'schema_version': schemaVersion,
    'min_supported_schema_version': 26,
  });

  /// 直近に送られた、このコマンドのフレーム。
  Map<String, dynamic>? lastOf(String command) {
    for (final frame in sent.reversed) {
      if (frame['command'] == command) return frame;
    }
    return null;
  }

  /// 指定コマンドに結果で応じる。`partial` なら続きがあるものとして送る。
  void reply(String command, {Object? result, bool partial = false}) {
    final frame = lastOf(command);
    if (frame == null) throw StateError('$command はまだ送られていない');
    emit({
      'message_id': frame['message_id'],
      'result': result,
      if (partial) 'partial': true,
    });
  }

  /// 指定コマンドをエラーで落とす。
  void fail(String command, int errorCode, [String? details]) {
    final frame = lastOf(command);
    if (frame == null) throw StateError('$command はまだ送られていない');
    emit({
      'message_id': frame['message_id'],
      'error_code': errorCode,
      'details': details,
    });
  }

  /// イベントを 1 件流す。
  void pushEvent(String event, {String? objectId, Object? data}) =>
      emit({'event': event, 'object_id': objectId, 'data': data});
}

/// Keychain を触らない [MaCredentials]。
class FakeMaCredentials extends MaCredentials {
  FakeMaCredentials([this.stored]);

  MaConnection? stored;

  @override
  Future<MaConnection?> load() async => stored;

  @override
  Future<void> save(MaConnection connection) async => stored = connection;

  @override
  Future<void> clear() async => stored = null;
}

final testMaConnection = MaConnection(
  baseUrl: Uri.parse('http://ma.local:8095'),
  token: 'ma-token',
);

/// `players/all` の 1 要素。
Map<String, Object?> playerJson(
  String id,
  String name, {
  bool available = true,
  String provider = 'wiim',
  int? volume = 40,
}) => {
  'player_id': id,
  'name': name,
  'available': available,
  'provider': provider,
  'volume_level': volume,
  'playback_state': 'idle',
};

/// `player_queues/all` の 1 要素。
Map<String, Object?> queueJson(
  String id, {
  String state = 'idle',
  int items = 0,
  double elapsed = 0,
  int? currentIndex,
  Map<String, Object?>? currentItem,
}) => {
  'queue_id': id,
  'display_name': id,
  'active': true,
  'items': items,
  'state': state,
  'elapsed_time': elapsed,
  'current_index': currentIndex,
  'current_item': currentItem,
};

/// キューの 1 行。
Map<String, Object?> queueItemJson(
  String id,
  String name, {
  int index = 0,
  String? artist,
  String uri = 'qobuz://track/1',
}) => {
  'queue_item_id': id,
  'name': name,
  'index': index,
  'duration': 180,
  'media_item': {
    'uri': uri,
    'name': name,
    'media_type': 'track',
    if (artist != null)
      'artists': [
        {'name': artist},
      ],
  },
};
