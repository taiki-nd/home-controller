import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ha_models.dart';
import '../services/ha_credentials.dart';
import '../services/home_assistant_api.dart';

/// 画面が知りたい接続状態。
enum HaStatus {
  /// 接続先がまだ入っていない。設定画面へ。
  needsSetup,

  connecting,
  connected,

  /// トークンが拒否された。**再接続しても直らない**ので設定画面へ。
  authFailed,

  /// 繋がらない・切れた。時間をおいて自動で繋ぎ直す。
  offline,
}

/// [HaSession] を作る口。テストで差し替える。
typedef HaSessionOpener = Future<HaSession> Function(HaConnection connection);

/// home 側の状態。
///
/// **状態は HA が持つ。** アプリは `state_changed` を購読して映すだけで、
/// 自前のキャッシュを真実にしない。Spotify 側の「アプリはステートレス」
/// （設計メモ §1）と同じ立て付けで、あちらのポーリングより正確に追える。
class HomeController extends ChangeNotifier {
  HomeController({HaCredentials? credentials, HaSessionOpener? open})
    : _credentials = credentials ?? HaCredentials(),
      _open = open ?? _defaultOpen;

  static Future<HaSession> _defaultOpen(HaConnection connection) =>
      HaSession.connect(connection);

  /// このラベルが付いたエンティティだけ出す。
  ///
  /// 並び順も追加も削除も HA 側で完結させるための仕掛け
  /// （`docs/home-assistant-integration.md` §8）。**1 つも付いていなければ
  /// 絞り込みをやめる** ので、ラベルを設定していなくても空にはならない。
  static const labelId = 'home-ctl';

  /// ラベル未設定のときに出すセンサー。全部出すとバッテリー残量などで埋まる。
  static const _defaultSensorClasses = {'temperature', 'humidity'};

  /// 楽観更新を信じておく時間。これを過ぎても `state_changed` が来なければ
  /// 戻して「応答なし」を出す。
  static const _optimisticWindow = Duration(seconds: 5);

  /// 再接続の間隔。頭打ちまで倍々にする。
  static const _reconnectMin = Duration(seconds: 2);
  static const _reconnectMax = Duration(seconds: 60);

  final HaCredentials _credentials;
  final HaSessionOpener _open;

  HaConnection? _connection;
  HaSession? _session;
  StreamSubscription<HaEntity>? _stateSub;
  Timer? _reconnect;
  Duration _backoff = _reconnectMin;

  final Map<String, HaEntity> _states = {};
  final Map<String, HaEntity> _optimistic = {};
  final Map<String, Timer> _optimisticTimers = {};
  HaRegistry _registry = HaRegistry.empty;

  HaStatus _status = HaStatus.connecting;
  String? _error;
  String? _selectedRoomId;
  bool _foreground = true;
  bool _disposed = false;

  HaStatus get status => _status;
  String? get errorBanner => _error;
  bool get isConfigured => _connection != null;
  HaConnection? get connection => _connection;

  /// 設定画面を出すべきか。
  bool get needsSetup =>
      _status == HaStatus.needsSetup || _status == HaStatus.authFailed;

  /// 表示対象のエンティティ（楽観更新を被せたあとの値）。
  List<HaEntity> get entities {
    final list = _states.keys.map(_resolve).where(_isVisible).toList();
    list.sort(_byRoomThenName);
    return list;
  }

  /// 部屋。中身のあるものだけ、名前順。area なしは最後にまとめる。
  List<HaRoom> get rooms {
    final ids = <String>{};
    for (final entity in entities) {
      ids.add(_registry.areaOf(entity.entityId) ?? HaRoom.unassignedId);
    }
    final rooms = ids
        .where((id) => id != HaRoom.unassignedId)
        .map((id) => HaRoom(id: id, name: _registry.areaNames[id] ?? id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (ids.contains(HaRoom.unassignedId)) {
      rooms.add(
        HaRoom(
          id: HaRoom.unassignedId,
          // レジストリごと引けなかった場合は「その他」ではなく全体扱いにする。
          name: _registry.isEmpty ? 'すべて' : 'その他',
        ),
      );
    }
    return rooms;
  }

  String? get selectedRoomId {
    final all = rooms;
    if (all.isEmpty) return null;
    final selected = _selectedRoomId;
    if (selected != null && all.any((r) => r.id == selected)) return selected;
    return all.first.id;
  }

  /// いま選んでいる部屋の、操作できるタイル。
  List<HaEntity> get tiles => _inSelectedRoom
      .where((e) => e.kind != HaTileKind.readout)
      .toList();

  /// いま選んでいる部屋の、押せない数値。
  List<HaEntity> get readouts => _inSelectedRoom
      .where((e) => e.kind == HaTileKind.readout)
      .toList();

  /// Drawer に出す「いくつ点いているか」。部屋をまたいで数える。
  int get onCount => entities
      .where((e) => e.kind == HaTileKind.toggle || e.kind == HaTileKind.climate)
      .where((e) => e.isOn)
      .length;

  /// その部屋で何か点いているか（部屋レールの点）。
  bool roomHasOn(String roomId) => entities
      .where((e) => (_registry.areaOf(e.entityId) ?? HaRoom.unassignedId) == roomId)
      .any((e) => e.isOn);

  List<HaEntity> get _inSelectedRoom {
    final room = selectedRoomId;
    if (room == null) return const [];
    return entities
        .where(
          (e) =>
              (_registry.areaOf(e.entityId) ?? HaRoom.unassignedId) == room,
        )
        .toList();
  }

  /// 起動時に一度だけ。保存済みの接続先で繋ぎに行く。
  Future<void> start() async {
    _connection = await _credentials.load();
    if (_connection == null) {
      _set(HaStatus.needsSetup);
      return;
    }
    await _connect();
  }

  /// 設定画面から新しい接続先を受け取る。
  Future<void> save(HaConnection connection) async {
    await _credentials.save(connection);
    _connection = connection;
    _error = null;
    await _connect();
  }

  /// 接続先を消して設定画面に戻す。
  Future<void> forget() async {
    await _credentials.clear();
    await _teardown();
    _connection = null;
    _states.clear();
    _clearAllOptimistic();
    _registry = HaRegistry.empty;
    _set(HaStatus.needsSetup);
  }

  /// バックグラウンドでは繋ぎっぱなしにしない。
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      if (_status != HaStatus.connected && _connection != null) _connect();
    } else {
      _teardown();
    }
  }

  void selectRoom(String roomId) {
    if (_selectedRoomId == roomId) return;
    _selectedRoomId = roomId;
    notifyListeners();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// いますぐ繋ぎ直す（エラーバナーの「再試行」）。
  Future<void> retry() async {
    if (_connection == null) return start();
    _backoff = _reconnectMin;
    return _connect();
  }

  // ── 操作 ────────────────────────────────────────────────────────────

  /// ON/OFF を入れ替える。
  ///
  /// タップした瞬間に UI を反転させ、`state_changed` が来たら確定。
  /// 来なければ [_optimisticWindow] で元に戻す。
  Future<void> toggle(HaEntity entity) async {
    if (entity.domain == 'climate') return _toggleClimate(entity);
    final turnOn = !entity.isOn;
    _optimisticSet(entity.copyWith(state: turnOn ? 'on' : 'off'));
    await _call(
      entity,
      entity.domain,
      turnOn ? 'turn_on' : 'turn_off',
    );
  }

  Future<void> _toggleClimate(HaEntity entity) async {
    if (entity.isOn) {
      _optimisticSet(entity.copyWith(state: 'off'));
      await _call(entity, 'climate', 'set_hvac_mode', {'hvac_mode': 'off'});
      return;
    }
    // `climate.turn_on` は実装していない機種がある。モードを直に入れるほうが確実。
    final mode = entity.preferredHvacMode;
    if (mode == null) {
      _fail('${entity.name}の運転モードが分かりませんでした');
      return;
    }
    _optimisticSet(entity.copyWith(state: mode));
    await _call(entity, 'climate', 'set_hvac_mode', {'hvac_mode': mode});
  }

  /// シーン・スクリプト・ボタン。状態を持たないので楽観更新もしない。
  Future<void> press(HaEntity entity) async {
    final service = switch (entity.domain) {
      'button' => 'press',
      _ => 'turn_on',
    };
    await _call(entity, entity.domain, service);
  }

  /// エアコンの設定温度を 1 段ずらす。
  Future<void> nudgeTemperature(HaEntity entity, int steps) async {
    final base = entity.targetTemperature ?? entity.currentTemperature;
    if (base == null) {
      _fail('${entity.name}の設定温度が取れませんでした');
      return;
    }
    final min = entity.minTemperature ?? 7;
    final max = entity.maxTemperature ?? 35;
    final next = (base + entity.temperatureStep * steps).clamp(min, max);
    if (next == base) return;
    _optimisticSet(
      entity.copyWith(
        attributes: {...entity.attributes, 'temperature': next},
      ),
    );
    await _call(entity, 'climate', 'set_temperature', {'temperature': next});
  }

  /// 明るさ（0–100%）。0 は消灯として送る。
  Future<void> setBrightnessPercent(HaEntity entity, int percent) async {
    final value = percent.clamp(0, 100);
    if (value == 0) {
      _optimisticSet(entity.copyWith(state: 'off'));
      await _call(entity, 'light', 'turn_off');
      return;
    }
    _optimisticSet(
      entity.copyWith(
        state: 'on',
        attributes: {
          ...entity.attributes,
          'brightness': (value * 255 / 100).round(),
        },
      ),
    );
    await _call(entity, 'light', 'turn_on', {'brightness_pct': value});
  }

  Future<void> _call(
    HaEntity entity,
    String domain,
    String service, [
    Map<String, Object?> data = const {},
  ]) async {
    final session = _session;
    if (session == null || session.isClosed) {
      _clearOptimistic(entity.entityId);
      _fail('Home Assistant に接続していません');
      return;
    }
    try {
      await session.callService(
        domain,
        service,
        entityId: entity.entityId,
        data: data,
      );
    } on HaException catch (e) {
      _clearOptimistic(entity.entityId);
      _fail('${entity.name}: ${e.message}');
    }
  }

  // ── 接続 ────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    final connection = _connection;
    if (connection == null) return;
    _reconnect?.cancel();
    await _teardown();
    _set(HaStatus.connecting);
    try {
      final session = await _open(connection);
      if (_disposed) {
        await session.close();
        return;
      }
      _session = session;
      await session.subscribeStateChanges();
      final states = await session.fetchStates();
      final registry = await session.fetchRegistry();
      if (_disposed) return;
      _states
        ..clear()
        ..addEntries(states.map((e) => MapEntry(e.entityId, e)));
      _registry = registry;
      _clearAllOptimistic();
      _stateSub = session.stateChanges.listen(_onStateChanged);
      // 落ちたら繋ぎ直す。close() を自分で呼んだときは _session を先に
      // 差し替えてあるので、ここは「意図しない切断」だけを拾う。
      session.done.then((_) {
        if (_session == session) _onDropped();
      });
      _backoff = _reconnectMin;
      _error = null;
      _set(HaStatus.connected);
    } on HaAuthException catch (e) {
      // 繋ぎ直しても直らない。リトライを回さずに設定画面へ倒す。
      _error = e.message;
      _set(HaStatus.authFailed);
    } on HaException catch (e) {
      _error = e.message;
      _set(HaStatus.offline);
      _scheduleReconnect();
    }
  }

  void _onDropped() {
    if (_disposed) return;
    _session = null;
    _stateSub?.cancel();
    _stateSub = null;
    _error = 'Home Assistant との接続が切れました';
    _set(HaStatus.offline);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_foreground || _disposed || _connection == null) return;
    _reconnect?.cancel();
    _reconnect = Timer(_backoff, _connect);
    final next = _backoff * 2;
    _backoff = next > _reconnectMax ? _reconnectMax : next;
  }

  Future<void> _teardown() async {
    _reconnect?.cancel();
    _reconnect = null;
    final session = _session;
    final sub = _stateSub;
    _session = null;
    _stateSub = null;
    // **先に close を呼ぶ。** close は同期的に ping タイマーまで畳むので、
    // dispose を await しない呼び出し側（画面の破棄）でもタイマーが残らない。
    final closing = session?.close();
    await sub?.cancel();
    await closing;
  }

  void _onStateChanged(HaEntity entity) {
    _states[entity.entityId] = entity;
    // HA から本物が来た。楽観更新の役目はここで終わり。
    _clearOptimistic(entity.entityId, notify: false);
    notifyListeners();
  }

  // ── 楽観更新 ────────────────────────────────────────────────────────

  HaEntity _resolve(String entityId) =>
      _optimistic[entityId] ?? _states[entityId]!;

  void _optimisticSet(HaEntity next) {
    _optimistic[next.entityId] = next;
    _optimisticTimers[next.entityId]?.cancel();
    _optimisticTimers[next.entityId] = Timer(_optimisticWindow, () {
      _clearOptimistic(next.entityId);
      _fail('${next.name}が応答しませんでした');
    });
    notifyListeners();
  }

  void _clearOptimistic(String entityId, {bool notify = true}) {
    _optimisticTimers.remove(entityId)?.cancel();
    if (_optimistic.remove(entityId) != null && notify) notifyListeners();
  }

  void _clearAllOptimistic() {
    for (final timer in _optimisticTimers.values) {
      timer.cancel();
    }
    _optimisticTimers.clear();
    _optimistic.clear();
  }

  // ── 表示対象の選抜 ──────────────────────────────────────────────────

  bool _isVisible(HaEntity entity) {
    if (entity.kind == HaTileKind.unsupported) return false;
    if (_registry.anyWithLabel(labelId)) {
      return _registry.hasLabel(entity.entityId, labelId);
    }
    // ラベル未設定。センサーは種類を絞らないとバッテリー残量などで埋まる。
    if (entity.domain == 'sensor') {
      return _defaultSensorClasses.contains(entity.deviceClass);
    }
    if (entity.domain == 'binary_sensor') return false;
    // オートメーションも、ラベルで選ばれていないうちは出さない。
    return entity.domain != 'automation';
  }

  int _byRoomThenName(HaEntity a, HaEntity b) {
    // 同じ部屋の中では、押せるものが先・数値が後。あとは名前順。
    final byKind = _kindOrder(a.kind).compareTo(_kindOrder(b.kind));
    if (byKind != 0) return byKind;
    return a.name.compareTo(b.name);
  }

  static int _kindOrder(HaTileKind kind) => switch (kind) {
    HaTileKind.toggle => 0,
    HaTileKind.climate => 1,
    HaTileKind.press => 2,
    HaTileKind.readout => 3,
    HaTileKind.unsupported => 4,
  };

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  void _set(HaStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearAllOptimistic();
    _teardown();
    super.dispose();
  }
}
