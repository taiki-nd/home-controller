import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ma_models.dart';
import '../services/ma_credentials.dart';
import '../services/music_assistant_api.dart';

/// 画面が知りたい接続状態。[HaStatus] と同じ 5 つ。
enum MaStatus {
  /// 接続先がまだ入っていない。設定画面へ。
  needsSetup,

  connecting,
  connected,

  /// トークンが拒否された。**再接続しても直らない**ので設定画面へ。
  authFailed,

  /// 繋がらない・切れた。時間をおいて自動で繋ぎ直す。
  offline,
}

/// 下のタブ。
enum MaTab { queue, search }

/// [MaSession] を作る口。テストで差し替える。
typedef MaSessionOpener = Future<MaSession> Function(MaConnection connection);

/// Music Assistant 側の状態。
///
/// **状態は MA が持つ。** イベントを映すだけで自前のキャッシュを真実にしない
/// （`docs/music-assistant-integration.md` §5）。楽観更新は入れない——
/// MA は操作の結果を数百 ms でイベントとして返すので、二重管理を増やす価値がない。
class MaController extends ChangeNotifier {
  MaController({MaCredentials? credentials, MaSessionOpener? open})
    : _credentials = credentials ?? MaCredentials(),
      _open = open ?? _defaultOpen;

  static Future<MaSession> _defaultOpen(MaConnection connection) =>
      MaSession.connect(connection);

  /// 再接続の間隔。頭打ちまで倍々にする。
  static const _reconnectMin = Duration(seconds: 2);
  static const _reconnectMax = Duration(seconds: 60);

  /// 検索を投げるまでの猶予。打ち終わる前に毎文字投げると Qobuz を叩きすぎる。
  static const _searchDebounce = Duration(milliseconds: 450);

  /// キューを一度に引く件数。壁掛けで指で送れる範囲を超えても読めないので、
  /// 全件は引かない。
  static const _queuePageSize = 100;

  final MaCredentials _credentials;
  final MaSessionOpener _open;

  MaConnection? _connection;
  MaSession? _session;
  StreamSubscription<MaEvent>? _eventSub;
  Timer? _reconnect;
  Timer? _searchDebounceTimer;
  Duration _backoff = _reconnectMin;

  final Map<String, MaPlayer> _players = {};
  final Map<String, MaQueue> _queues = {};
  List<MaQueueItem> _items = const [];

  MaStatus _status = MaStatus.connecting;
  String? _error;
  String? _selectedPlayerId;
  MaTab _tab = MaTab.queue;
  String _query = '';
  MaSearchResults _results = const MaSearchResults();
  bool _searchBusy = false;
  String? _toast;
  bool _foreground = true;
  bool _disposed = false;

  /// シークバーだけを毎秒描き直すための口。
  ///
  /// `queue_time_updated` は再生中ずっと毎秒飛んでくる。これで
  /// [notifyListeners] を叩くと画面全部が毎秒作り直しになるので、進捗の
  /// 購読者だけ別にする（Spotify 側の `progressTick` と同じ）。
  final ChangeNotifier progressTick = ChangeNotifier();

  MaStatus get status => _status;
  String? get errorBanner => _error;
  String? get toast => _toast;
  bool get isConfigured => _connection != null;
  MaConnection? get connection => _connection;
  MaTab get tab => _tab;
  String get query => _query;
  MaSearchResults get results => _results;
  bool get searchBusy => _searchBusy;

  /// 設定画面を出すべきか。
  bool get needsSetup =>
      _status == MaStatus.needsSetup || _status == MaStatus.authFailed;

  /// アートワークの URL を組み立てるための土台。
  Uri? get imageBase => _connection?.baseUrl;

  /// 選べる出力先。名前順。
  List<MaPlayer> get players {
    final list = _players.values.where((p) => p.isSelectable).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// いま操作している出力先。
  ///
  /// 明示的に選んでいなければ、**鳴っているものを拾う。** 壁掛けの前に来た人が
  /// 何も選ばずに一時停止を押せるようにするため。
  MaPlayer? get selectedPlayer {
    final all = players;
    if (all.isEmpty) return null;
    final selected = _selectedPlayerId;
    if (selected != null) {
      for (final player in all) {
        if (player.playerId == selected) return player;
      }
    }
    for (final player in all) {
      if (_queues[player.queueId]?.isPlaying == true) return player;
    }
    return all.first;
  }

  /// いま操作しているキュー。
  MaQueue? get queue {
    final player = selectedPlayer;
    return player == null ? null : _queues[player.queueId];
  }

  MaQueueItem? get currentItem => queue?.currentItem;

  /// キューの「これから」。いま鳴っている曲より後ろだけ。
  List<MaQueueItem> get upNext {
    final index = queue?.currentIndex;
    if (index == null) return _items;
    return _items.where((item) => item.index > index).toList();
  }

  bool get isPlaying => queue?.isPlaying ?? false;

  Duration get position => queue?.correctedElapsed(DateTime.now()) ?? Duration.zero;

  Duration get duration => currentItem?.duration ?? Duration.zero;

  double get progressFraction {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// Drawer に添える一行（`AppShell` の `_ShellDrawer`）。
  String? get drawerSubtitle => switch (_status) {
    MaStatus.needsSetup => '未設定',
    MaStatus.authFailed => 'トークンが拒否されました',
    MaStatus.connecting => '接続中…',
    MaStatus.offline => 'オフライン',
    MaStatus.connected => currentItem?.title ?? '停止中',
  };

  // ── 出入り ──────────────────────────────────────────────────────────

  /// 起動時に一度だけ。保存済みの接続先で繋ぎに行く。
  Future<void> start() async {
    _connection = await _credentials.load();
    if (_connection == null) {
      _set(MaStatus.needsSetup);
      return;
    }
    await _connect();
  }

  /// 設定画面から新しい接続先を受け取る。
  Future<void> save(MaConnection connection) async {
    await _credentials.save(connection);
    _connection = connection;
    _error = null;
    _backoff = _reconnectMin;
    await _connect();
  }

  /// 接続先を消して設定画面に戻す。
  Future<void> forget() async {
    await _credentials.clear();
    await _teardown();
    _connection = null;
    _players.clear();
    _queues.clear();
    _items = const [];
    _set(MaStatus.needsSetup);
  }

  /// バックグラウンドでは繋ぎっぱなしにしない。
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      if (_status != MaStatus.connected && _connection != null) _connect();
    } else {
      _teardown();
    }
  }

  /// いますぐ繋ぎ直す（エラーバナーの「再試行」）。
  Future<void> retry() async {
    if (_connection == null) return start();
    _backoff = _reconnectMin;
    return _connect();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void dismissToast() {
    if (_toast == null) return;
    _toast = null;
    notifyListeners();
  }

  // ── 選択 ────────────────────────────────────────────────────────────

  Future<void> selectPlayer(MaPlayer player) async {
    if (_selectedPlayerId == player.playerId) return;
    _selectedPlayerId = player.playerId;
    _items = const [];
    notifyListeners();
    await _loadItems(player.queueId);
  }

  void selectTab(MaTab value) {
    if (_tab == value) return;
    _tab = value;
    notifyListeners();
  }

  // ── 操作 ────────────────────────────────────────────────────────────

  Future<void> togglePlayPause() =>
      _command((session, queueId) => session.playPause(queueId));

  Future<void> skipNext() =>
      _command((session, queueId) => session.next(queueId));

  Future<void> skipPrevious() =>
      _command((session, queueId) => session.previous(queueId));

  Future<void> seek(Duration position) =>
      _command((session, queueId) => session.seek(queueId, position));

  Future<void> setShuffle(bool value) =>
      _command((session, queueId) => session.setShuffle(queueId, value));

  /// off → all → one → off。
  Future<void> cycleRepeat() {
    final next = (queue?.repeatMode ?? MaRepeatMode.off).next;
    return _command((session, queueId) => session.setRepeat(queueId, next));
  }

  Future<void> playItem(MaQueueItem item) =>
      _command((session, queueId) => session.playIndex(queueId, item.index));

  Future<void> removeItem(MaQueueItem item) => _command(
    (session, queueId) => session.deleteItem(queueId, item.queueItemId),
  );

  Future<void> setVolume(int level) async {
    final session = _session;
    final player = selectedPlayer;
    if (session == null || player == null) return;
    try {
      await session.setVolume(player.playerId, level);
    } on MaException catch (e) {
      _fail(e.message);
    }
  }

  /// 検索結果をキューに積む。
  Future<void> enqueue(
    MaMediaItem item, {
    MaQueueOption option = MaQueueOption.add,
  }) async {
    final ok = await _command(
      (session, queueId) => session.playMedia(queueId, item.uri, option: option),
    );
    if (!ok) return;
    _toast = switch (option) {
      MaQueueOption.play || MaQueueOption.replace => '${item.name} を再生',
      MaQueueOption.next => '${item.name} を次に',
      MaQueueOption.add => '${item.name} をキューに追加',
    };
    notifyListeners();
  }

  /// 成否を返す（true なら送れた）。トーストの出し分けに使う。
  Future<bool> _command(
    Future<void> Function(MaSession session, String queueId) run,
  ) async {
    final session = _session;
    final player = selectedPlayer;
    if (session == null || session.isClosed || player == null) {
      _fail('Music Assistant に接続していません');
      return false;
    }
    try {
      await run(session, player.queueId);
      return true;
    } on MaException catch (e) {
      _fail(e.message);
      return false;
    }
  }

  // ── 検索 ────────────────────────────────────────────────────────────

  void onQueryChanged(String value) {
    _query = value;
    _searchDebounceTimer?.cancel();
    final text = value.trim();
    if (text.isEmpty) {
      _results = const MaSearchResults();
      _searchBusy = false;
      notifyListeners();
      return;
    }
    _searchBusy = true;
    notifyListeners();
    _searchDebounceTimer = Timer(_searchDebounce, () => _runSearch(text));
  }

  Future<void> _runSearch(String text) async {
    final session = _session;
    if (session == null || session.isClosed) {
      _searchBusy = false;
      _fail('Music Assistant に接続していません');
      return;
    }
    try {
      final results = await session.search(text);
      // 打ち直されていたら捨てる。
      if (_disposed || _query.trim() != text) return;
      _results = results;
      _searchBusy = false;
      notifyListeners();
    } on MaException catch (e) {
      if (_disposed || _query.trim() != text) return;
      _searchBusy = false;
      _fail(e.message);
    }
  }

  // ── 接続 ────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    final connection = _connection;
    if (connection == null) return;
    _reconnect?.cancel();
    await _teardown();
    _set(MaStatus.connecting);
    try {
      final session = await _open(connection);
      if (_disposed) {
        await session.close();
        return;
      }
      _session = session;
      // イベントは購読コマンド無しで流れてくる（§2）。取りこぼさないよう、
      // 初期状態を引く前に聞き始める。
      _eventSub = session.events.listen(_onEvent);
      final players = await session.fetchPlayers();
      final queues = await session.fetchQueues();
      if (_disposed) return;
      _players
        ..clear()
        ..addEntries(players.map((p) => MapEntry(p.playerId, p)));
      _queues
        ..clear()
        ..addEntries(queues.map((q) => MapEntry(q.queueId, q)));
      session.done.then((_) {
        if (_session == session) _onDropped();
      });
      _backoff = _reconnectMin;
      _error = null;
      _set(MaStatus.connected);
      final queueId = selectedPlayer?.queueId;
      if (queueId != null) await _loadItems(queueId);
    } on MaAuthException catch (e) {
      // 繋ぎ直しても直らない。リトライを回さずに設定画面へ倒す。
      _error = e.message;
      _set(MaStatus.authFailed);
    } on MaException catch (e) {
      _error = e.message;
      _set(MaStatus.offline);
      _scheduleReconnect();
    }
  }

  void _onDropped() {
    if (_disposed) return;
    _session = null;
    _eventSub?.cancel();
    _eventSub = null;
    _error = 'Music Assistant との接続が切れました';
    _set(MaStatus.offline);
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
    final sub = _eventSub;
    _session = null;
    _eventSub = null;
    // **先に close を呼ぶ。** 同期的に待ち行列を畳むので、dispose を await
    // しない呼び出し側でも取り残しが出ない（`HomeController._teardown` と同じ）。
    final closing = session?.close();
    await sub?.cancel();
    await closing;
  }

  Future<void> _loadItems(String queueId) async {
    final session = _session;
    if (session == null || session.isClosed) return;
    try {
      final items = await session.fetchQueueItems(
        queueId,
        limit: _queuePageSize,
      );
      // 読んでいる間に出力先を切り替えられていたら捨てる。
      if (_disposed || selectedPlayer?.queueId != queueId) return;
      _items = items;
      notifyListeners();
    } on MaException catch (e) {
      debugPrint('MaController._loadItems failed: ${e.message}');
    }
  }

  void _onEvent(MaEvent event) {
    final id = event.objectId;
    switch (event.type) {
      case 'player_added' || 'player_updated':
        final data = event.data;
        if (data is! Map) return;
        final player = MaPlayer.fromJson(Map<String, dynamic>.from(data));
        _players[player.playerId] = player;
        notifyListeners();

      case 'player_removed':
        if (id == null) return;
        if (_players.remove(id) != null) notifyListeners();

      case 'queue_added' || 'queue_updated':
        final data = event.data;
        if (data is! Map) return;
        final queue = MaQueue.fromJson(Map<String, dynamic>.from(data));
        final previous = _queues[queue.queueId];
        _queues[queue.queueId] = queue;
        // 曲が変わったらキューの先頭がずれる。中身を引き直す。
        if (previous?.currentIndex != queue.currentIndex &&
            queue.queueId == selectedPlayer?.queueId) {
          _loadItems(queue.queueId);
        }
        notifyListeners();

      case 'queue_items_updated':
        if (id == null || id != selectedPlayer?.queueId) return;
        _loadItems(id);

      case 'queue_time_updated':
        // data は経過秒（数値）だけ。**ここで notifyListeners は叩かない。**
        final seconds = event.data;
        if (id == null || seconds is! num) return;
        final queue = _queues[id];
        if (queue == null) return;
        _queues[id] = queue.copyWith(
          elapsed: Duration(milliseconds: (seconds * 1000).round()),
          elapsedAt: DateTime.now(),
        );
        if (id == selectedPlayer?.queueId) progressTick.notifyListeners();
    }
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  void _set(MaStatus status) {
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
    _searchDebounceTimer?.cancel();
    _teardown();
    progressTick.dispose();
    super.dispose();
  }
}
