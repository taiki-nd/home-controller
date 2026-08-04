import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/ha_models.dart';
import 'ha_credentials.dart';
import 'ha_socket.dart';

/// HA とのやり取りが失敗した。文言はそのまま画面に出す前提で作る。
class HaException implements Exception {
  HaException(this.message);

  final String message;

  @override
  String toString() => 'HaException: $message';
}

/// トークンが拒否された（`auth_invalid`）。
///
/// **通信断と必ず区別する。** 再接続しても直らないので、リトライを回さずに
/// 設定画面へ戻す。
class HaAuthException extends HaException {
  HaAuthException(super.message);
}

/// WebSocket 1 本ぶんのセッション。
///
/// 切れたら作り直す。**再接続のループはここに持たない**（何回・何秒あけて
/// やり直すかは画面の都合なので [HomeController] 側が決める）。
///
/// プロトコル: 繋ぐと `auth_required` が来る → `auth` を送る → `auth_ok`。
/// 以降はコマンドに id を振り、同じ id の `result` が返る。
class HaSession {
  HaSession(this._socket) {
    _sub = _socket.messages.listen(
      _onMessage,
      onError: (Object e) => _finish(HaException('接続が切れました: $e')),
      onDone: () => _finish(HaException('接続が切れました')),
    );
  }

  /// 接続してから `auth_ok` が返るまで待つ。
  static Future<HaSession> connect(
    HaConnection connection, {
    HaSocketOpener opener = WebSocketHaSocket.open,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final HaSocket socket;
    try {
      socket = await opener(connection.websocketUrl).timeout(timeout);
    } on TimeoutException {
      throw HaException('Home Assistant に接続できませんでした（応答なし）');
    } catch (e) {
      debugPrint('HaSession.connect failed: $e');
      throw HaException('Home Assistant に接続できませんでした');
    }
    final session = HaSession(socket);
    try {
      await session._authenticate(connection.token).timeout(timeout);
    } catch (e) {
      await session.close();
      if (e is TimeoutException) {
        throw HaException('Home Assistant が認証に応答しませんでした');
      }
      rethrow;
    }
    return session;
  }

  /// 1 コマンドの待ち時間。壁掛けで固まったままにしないための上限。
  static const _requestTimeout = Duration(seconds: 15);

  /// 死んだ接続を検出する間隔。HA 側からは何も来ないので、こちらから叩く。
  static const _pingInterval = Duration(seconds: 30);

  final HaSocket _socket;
  late final StreamSubscription<String> _sub;

  final _pending = <int, Completer<Object?>>{};
  final _stateChanges = StreamController<HaEntity>.broadcast();
  final _done = Completer<void>();

  Completer<void>? _authGate;
  Timer? _ping;
  int _nextId = 1;
  bool _closed = false;

  /// `state_changed` で流れてくる新しい状態。
  Stream<HaEntity> get stateChanges => _stateChanges.stream;

  /// 接続が終わったら完了する。再接続の合図に使う。
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  Future<void> _authenticate(String token) async {
    // `auth_required` を待たずに送っても HA は受け取るが、順序が保証される
    // ぶん待ってから送る（先に auth を投げると古い版で無視される）。
    await _waitGate();
    _socket.send(jsonEncode({'type': 'auth', 'access_token': token}));
    await _waitGate();
    _ping = Timer.periodic(_pingInterval, (_) => _sendPing());
  }

  /// 次の `auth_required` / `auth_ok` / `auth_invalid` を 1 つ待つ。
  Future<void> _waitGate() {
    final gate = _authGate = Completer<void>();
    return gate.future.whenComplete(() => _authGate = null);
  }

  void _openGate() {
    final gate = _authGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _failGate(HaException reason) {
    final gate = _authGate;
    if (gate != null && !gate.isCompleted) gate.completeError(reason);
  }

  /// 全エンティティの現在値。
  Future<List<HaEntity>> fetchStates() async {
    final result = await _request({'type': 'get_states'});
    if (result is! List) throw HaException('状態の取得に失敗しました');
    return result
        .whereType<Map>()
        .map((e) => HaEntity.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `state_changed` の購読を始める。
  Future<void> subscribeStateChanges() =>
      _request({'type': 'subscribe_events', 'event_type': 'state_changed'});

  /// 部屋とラベルの対応表。
  ///
  /// **レジストリは管理者トークンでないと引けない。** 引けなくても操作自体は
  /// できるので、失敗したら空で返して部屋分けだけ諦める。
  Future<HaRegistry> fetchRegistry() async {
    try {
      final areas = await _request({'type': 'config/area_registry/list'});
      final devices = await _request({'type': 'config/device_registry/list'});
      final entities = await _request({'type': 'config/entity_registry/list'});
      if (areas is! List || devices is! List || entities is! List) {
        return HaRegistry.empty;
      }

      final areaNames = <String, String>{};
      for (final area in areas.whereType<Map>()) {
        final id = area['area_id'] as String?;
        final name = area['name'] as String?;
        if (id != null && name != null) areaNames[id] = name;
      }

      final deviceAreas = <String, String>{};
      for (final device in devices.whereType<Map>()) {
        final id = device['id'] as String?;
        final areaId = device['area_id'] as String?;
        if (id != null && areaId != null) deviceAreas[id] = areaId;
      }

      final entityAreas = <String, String>{};
      final entityLabels = <String, Set<String>>{};
      for (final entry in entities.whereType<Map>()) {
        final entityId = entry['entity_id'] as String?;
        if (entityId == null) continue;
        // エンティティに直接付いた area が優先。無ければデバイスの area を継ぐ。
        final areaId =
            entry['area_id'] as String? ?? deviceAreas[entry['device_id']];
        if (areaId != null) entityAreas[entityId] = areaId;
        final labels = entry['labels'];
        if (labels is List && labels.isNotEmpty) {
          entityLabels[entityId] = labels.whereType<String>().toSet();
        }
      }

      return HaRegistry(
        areaNames: areaNames,
        entityAreas: entityAreas,
        entityLabels: entityLabels,
      );
    } on HaException catch (e) {
      // 管理者でないトークンだとここに来る。操作はできるので続行する。
      debugPrint('HaSession.fetchRegistry skipped: ${e.message}');
      return HaRegistry.empty;
    }
  }

  /// `light.turn_on` などを叩く。
  Future<void> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, Object?> data = const {},
  }) {
    return _request({
      'type': 'call_service',
      'domain': domain,
      'service': service,
      if (entityId != null) 'target': {'entity_id': entityId},
      if (data.isNotEmpty) 'service_data': data,
    });
  }

  Future<Object?> _request(Map<String, Object?> body) {
    if (_closed) throw HaException('接続が切れています');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _socket.send(jsonEncode({...body, 'id': id}));
    return completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw HaException('Home Assistant が応答しませんでした');
      },
    );
  }

  void _sendPing() {
    // 返らなければ _requestTimeout で例外になり、接続を畳む。
    _request({'type': 'ping'}).catchError((Object e) {
      _finish(HaException('接続が切れました'));
      return null;
    });
  }

  void _onMessage(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);

    switch (message['type']) {
      case 'auth_required' || 'auth_ok':
        _openGate();
      case 'auth_invalid':
        _failGate(
          HaAuthException(
            message['message'] as String? ?? 'アクセストークンが拒否されました',
          ),
        );
      case 'result':
        final completer = _pending.remove(message['id']);
        if (completer == null) return;
        if (message['success'] == true) {
          completer.complete(message['result']);
        } else {
          final error = message['error'];
          final text = error is Map ? error['message'] as String? : null;
          completer.completeError(HaException(text ?? 'コマンドが失敗しました'));
        }
      case 'pong':
        _pending.remove(message['id'])?.complete(null);
      case 'event':
        _onEvent(message['event']);
    }
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    if (event['event_type'] != 'state_changed') return;
    final data = event['data'];
    if (data is! Map) return;
    final newState = data['new_state'];
    // 削除されたエンティティは new_state が null で来る。
    if (newState is! Map) return;
    _stateChanges.add(HaEntity.fromJson(Map<String, dynamic>.from(newState)));
  }

  /// 接続が終わった。待っている呼び出しを全部落としてから閉じる。
  void _finish(HaException reason) {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    _failGate(reason);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(reason);
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
    _stateChanges.close();
    _sub.cancel();
  }

  Future<void> close() async {
    _finish(HaException('切断しました'));
    await _socket.close();
  }
}
