import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:palette_generator/palette_generator.dart';

import '../models/spotify_models.dart';
import '../services/device_name_cache.dart';
import '../services/spotify_api.dart';
import '../theme/tokens.dart';

/// 右レール / ボトムシートのタブ。
///
/// **[RailTabs] は宣言順に `labels` を index で引く。** 並びを変えたり足したり
/// したら、あちらの labels も同じ順で直すこと。
enum RailTab { queue, search, playlists, newReleases }

/// アートワークから抜いた 2 色。背景グラデーションにだけ使う。
/// （Spotify デザインガイドライン上、アートワーク自体の加工はできない — 設計メモ §12）
class ArtworkPalette {
  const ArtworkPalette(this.deep, this.accent);

  static const fallback = ArtworkPalette(Color(0xFF1D1D24), Color(0xFF4A4A5C));

  final Color deep;
  final Color accent;
}

/// アプリの唯一のコントローラ。
///
/// **ローカルにキュー状態を持たない**（設計メモ §1）。ここにあるのは全て
/// 「直近に Spotify から取ってきたものの写し」と、UI の一時状態だけ。
class PlayerController extends ChangeNotifier {
  /// [now] はテスト用。ポーリングの間隔は「曲の残り時間」から決まるので、
  /// 時計を差し替えられないと fake_async でスケジュールを検証できない
  /// （fake_async が進めるのはタイマーだけで [DateTime.now] は実時刻のまま）。
  PlayerController(this._api, {DateTime Function()? now, DeviceNameCache? deviceNames})
    : _now = now ?? DateTime.now,
      _deviceNameCache = deviceNames {
    _playbackFetchedAt = _now();
  }

  final SpotifyApi _api;
  final DateTime Function() _now;

  /// null ならデバイス名の記憶をしない（テスト・モック用）。
  final DeviceNameCache? _deviceNameCache;

  // ── Spotify から取ってきたもの ────────────────────────────────────────
  PlaybackState _playback = PlaybackState.stopped;
  late DateTime _playbackFetchedAt;
  QueueSnapshot _queue = QueueSnapshot.empty;
  List<SpotifyDevice> _devices = const [];
  List<PlaylistSummary> _playlists = const [];

  // ── UI の一時状態 ────────────────────────────────────────────────────
  RailTab _tab = RailTab.queue;
  bool _sheetOpen = false;
  bool _devicesOpen = false;
  bool _deviceLost = false;
  bool _playlistsLoaded = false;
  String? _preferredDeviceId;

  /// 自分の user id。プレイリストの編集可否の判定だけに使う。
  String? _userId;

  /// 「追加先を選ぶ」モードで押された曲。
  Track? _addingTrack;

  /// デバイス id → 一度でも Spotify が返してきた本当の表示名。
  Map<String, String> _deviceNames = {};

  String? _toast;
  String? _errorBanner;
  Timer? _toastTimer;

  String _query = '';
  List<Track> _results = const [];
  int _searchOffset = 0;
  bool _searchHasMore = false;
  bool _searchBusy = false;
  int _searchGeneration = 0;
  Timer? _searchDebounce;

  ArtworkPalette _palette = ArtworkPalette.fallback;
  String? _paletteSourceUrl;

  bool _foreground = true;
  bool _disposed = false;
  Timer? _pollTimer;
  bool _polling = false;
  int _pollFailures = 0;
  int _boundaryRetries = 0;
  String? _lastQueueKey;

  /// 曲送りで先に画面を書き換えたときの、書き換え前の曲の URI。
  /// Spotify の再生状態は数百 ms 遅れて追いつくので、この URI を返してくる
  /// 間のポーリング結果は「まだ古い」とみなして捨てる。捨てないと
  /// 前の曲が一瞬戻ってから次の曲に変わる（＝スワイプがちらつく）。
  String? _staleUri;

  /// 上を捨て続ける期限。ここを過ぎたら諦めて真の状態を採る。
  DateTime? _skipUntil;

  /// 前の曲へ戻すとき用の再生履歴。新しいものが末尾。
  final List<Track> _history = [];
  static const _historyLimit = 20;

  /// 出しっぱなしにすべき失敗。通信のブレではなく Spotify 側の返答。
  static bool _isHardError(SpotifyApiException e) =>
      e.statusCode == 429 || e.statusCode == 403 || e.statusCode == 402;

  /// 進捗バーだけを 500ms で塗り替えるための別 Listenable。
  /// 全体を notifyListeners すると 2Hz で全再ビルドになるので分けている。
  final ChangeNotifier progressTick = ChangeNotifier();
  Timer? _tickTimer;

  // ── 参照用 getter ────────────────────────────────────────────────────

  PlaybackState get playback => _playback;
  Track? get currentTrack => _playback.track;
  List<Track> get upNext => _queue.upcoming;
  Track? get nextTrack => _queue.upcoming.isEmpty ? null : _queue.upcoming.first;

  /// NEXT UP カードで 1 曲目を出しているので、リストはその次から。
  List<Track> get restOfQueue =>
      _queue.upcoming.isEmpty ? const [] : _queue.upcoming.sublist(1);

  List<SpotifyDevice> get devices => _devices;
  List<PlaylistSummary> get playlists => _playlists;
  bool get playlistsLoaded => _playlistsLoaded;

  RailTab get tab => _tab;
  bool get sheetOpen => _sheetOpen;
  bool get devicesOpen => _devicesOpen && !_deviceLost;
  bool get deviceLost => _deviceLost;
  String? get toast => _toast;
  String? get errorBanner => _errorBanner;

  String get query => _query;
  List<Track> get results => _results;
  bool get searchBusy => _searchBusy;
  bool get searchHasMore => _searchHasMore;

  ArtworkPalette get palette => _palette;

  /// 204 NO CONTENT。「停止中」であってエラーではない（設計メモ §5）。
  bool get isStopped => !_playback.hasContent || _playback.track == null;

  bool get isPlaying => _playback.isPlaying && !isStopped;
  bool get shuffleOn => _playback.shuffleState;

  /// 停止バナー。デバイス消失中はそちらのオーバーレイを優先する。
  bool get showStoppedBanner => isStopped && !_deviceLost;

  SpotifyDevice? get activeDevice {
    final playing = _playback.device;
    if (playing != null) return _applyCachedName(playing);
    for (final device in _devices) {
      if (device.isActive) return device;
    }
    return null;
  }

  String get deviceLabel {
    if (_deviceLost) return 'No device';
    return activeDevice?.name ??
        _devices
            .where((d) => d.id == _preferredDeviceId)
            .map((d) => d.name)
            .firstOrNull ??
        'Choose device';
  }

  Color get deviceDotColor {
    if (_deviceLost) return AppColors.danger;
    if (isStopped) return AppColors.amber;
    return AppColors.green;
  }

  String get statusLabel {
    if (_deviceLost) return 'No device found';
    if (isStopped) return 'Stopped · 204 NO CONTENT';
    if (!_playback.isPlaying) return 'Paused';
    return shuffleOn ? 'Playing · Shuffle on' : 'Playing · Shuffle off';
  }

  /// 今どのプレイリストを base にしているか。context_uri から引き当てる。
  String get contextLabel {
    final uri = _playback.contextUri;
    if (uri == null) return 'No base playlist — queue only';
    for (final playlist in _playlists) {
      if (playlist.uri == uri) return 'Playing from ${playlist.name}';
    }
    return uri.startsWith('spotify:playlist:')
        ? 'Playing from a playlist'
        : 'Playing from Spotify';
  }

  bool isContext(PlaylistSummary playlist) =>
      _playback.contextUri == playlist.uri;

  /// 進捗は毎回 API を叩かず、取得した progress_ms を起点にローカル内挿する
  /// （設計メモ §8）。
  Duration get position {
    final base = Duration(milliseconds: _playback.progressMs);
    if (!isPlaying) return base;
    final elapsed = _now().difference(_playbackFetchedAt);
    final total = base + elapsed;
    final duration = this.duration;
    return total > duration ? duration : total;
  }

  Duration get duration =>
      Duration(milliseconds: currentTrack?.durationMs ?? 0);

  double get progressFraction {
    final total = duration.inMilliseconds;
    if (total <= 0 || isStopped) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// コマンドの宛先。明示選択 > いま鳴っているデバイス。
  /// どちらも無ければ null を渡し、Spotify 側の「アクティブデバイス」に任せる。
  String? get _targetDeviceId => _preferredDeviceId ?? activeDevice?.id;

  // ── ライフサイクル ────────────────────────────────────────────────────

  Future<void> start() async {
    // 名前の記憶はデバイス取得より先に読む。後だと初回だけ Unknown が出る。
    _deviceNames = await _deviceNameCache?.load() ?? {};
    await refreshDevices(silent: true);
    await _pollOnce();
    unawaited(loadPlaylists());
    unawaited(_loadUserId());
  }

  /// バックグラウンドではポーリングを完全に止める（設計メモ §8）。
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      unawaited(_pollOnce());
    } else {
      _pollTimer?.cancel();
      _tickTimer?.cancel();
      _tickTimer = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _toastTimer?.cancel();
    _searchDebounce?.cancel();
    progressTick.dispose();
    super.dispose();
  }

  // ── ポーリング ────────────────────────────────────────────────────────

  Future<void> _pollOnce() async {
    if (_disposed || _polling || !_foreground) return;
    _polling = true;
    try {
      final state = await _api.playbackState();
      _pollFailures = 0;
      if (_isStaleAfterSkip(state)) {
        // まだ送る前の曲が返ってきている。先に出した次の曲を残したまま、
        // finally のスケジューラに任せてすぐ訊き直す。
        return;
      }
      _staleUri = null;
      _skipUntil = null;
      _pushHistoryIfChanged(state.track);
      // 鳴っている先の名前もここで覚える（一覧より先に取れることがある）。
      _applyCachedNames([?state.device]);
      _playback = state;
      _playbackFetchedAt = _now();
      _errorBanner = null;
      if (state.hasContent) {
        // 再生できているならデバイスは生きている。
        _deviceLost = false;
      }
      unawaited(_updatePalette(state.track));

      // キューは「曲が変わったとき」だけ取り直す（設計メモ §8）。
      final key = state.track?.uri;
      if (key != _lastQueueKey) {
        _lastQueueKey = key;
        _boundaryRetries = 0; // 曲が変わったので終了予測の追い込みは終わり
        await _refreshQueue();
      }
      notifyListeners();
    } on SpotifyAuthExpiredException {
      // AuthService 側が既にサインアウト済み。ルートが Login に切り替わる。
      return;
    } on NoActiveDeviceException {
      // デバイス消失は refreshDevices / NoDeviceOverlay の担当。バナーは出さない。
      _pollFailures = 0;
    } on SpotifyApiException catch (e) {
      _pollFailures++;
      debugPrint('poll failed ($_pollFailures 回目): $e');
      // 一瞬の通信断でバナーが点滅すると鬱陶しいので、原因がはっきりしている
      // ものは即時、それ以外は 3 回続けて失敗してから出す。
      if (_isHardError(e) || _pollFailures >= 3) {
        _errorBanner = e.message;
        notifyListeners();
      }
    } finally {
      _polling = false;
      _syncTicker();
      _scheduleNextPoll();
    }
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    if (_disposed || !_foreground) return;
    _pollTimer = Timer(_nextPollDelay(), _pollOnce);
  }

  /// 一定間隔では回さない。叩く理由があるときだけ起きる。
  ///
  /// 進捗バーは progress_ms からローカル内挿しているので（[position]）、
  /// 間隔を詰めても見た目は良くならない。「自分が起こしていない変化」だけが
  /// 取りに行く理由で、それは 2 つしかない:
  ///
  /// 1. 曲が自然に終わる — [duration] と progress_ms から**予測できる**ので、
  ///    終わる時刻に 1 回だけ起こす。
  /// 2. 他のクライアントからの操作 — 予測できないのでハートビートで拾う。
  ///    この間隔がそのまま「外部操作に気づくまでの最大待ち時間」になる。
  Duration _nextPollDelay() {
    final cooldown = _api.rateLimitCooldown;
    if (cooldown != null) {
      // クールダウンは数時間になることがある（Development Mode で枠を使い切ると
      // Spotify は Retry-After に 5 時間近くを返してくる）。そのまま寝かせると
      // バナーの「あと N」が固まったままになるので、最長 1 分で起こして出し直す。
      // 待機中は [SpotifyApi._send] が通信前に弾くので追加のリクエストは出ない。
      return _atMost(cooldown + const Duration(milliseconds: 250), _heartbeat);
    }
    // 曲送りの反映待ち。追いつくまで短い間隔で訊き直す。
    if (_skipUntil != null && _now().isBefore(_skipUntil!)) {
      return const Duration(milliseconds: 350);
    }
    if (_pollFailures > 0) {
      // 失敗が続いている間は下がっていく。回復したら 0 に戻る。
      return Duration(seconds: (3 * (1 << _pollFailures)).clamp(3, 60));
    }
    if (!isPlaying) return _heartbeat;

    final total = duration;
    if (total == Duration.zero) return _heartbeat; // 尺不明なら予測できない
    final remaining =
        total -
        Duration(milliseconds: _playback.progressMs) -
        _now().difference(_playbackFetchedAt);

    if (remaining > _boundarySlack) {
      // まだ十分に先。曲の終わりに合わせて 1 回だけ起きる。
      // 少し過ぎてから訊かないと前の曲が返るので slack を足す。
      _boundaryRetries = 0;
      return _atMost(remaining + _boundarySlack, _heartbeat);
    }

    // 変わり目に来ているのに曲が変わっていない。バッファリングで延びたか、
    // 終端で止まっている（外部から一時停止された等）。
    //
    // ここを一律 slack で回すと、終端で止まったまま 1.5 秒間隔で叩き続けて
    // しまう。1.5s → 3s → 6s … と伸ばしてハートビートで頭打ちにする。
    // 曲が変われば [_pollOnce] が 0 に戻すので、通常は 1 回で終わる。
    _boundaryRetries++;
    return _atMost(_boundarySlack * (1 << (_boundaryRetries - 1)), _heartbeat);
  }

  /// 外部操作を拾うためだけの間隔。これがそのまま追従の遅れの上限になる。
  static const _heartbeat = Duration(seconds: 60);

  /// 曲の変わり目をどれだけ過ぎてから訊くか。
  static const _boundarySlack = Duration(milliseconds: 1500);

  static Duration _atMost(Duration d, Duration cap) => d > cap ? cap : d;

  /// 再生中だけ進捗バー用のティッカーを回す。
  void _syncTicker() {
    final wanted = isPlaying && _foreground;
    if (wanted && _tickTimer == null) {
      _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!_disposed) progressTick.notifyListeners();
      });
    } else if (!wanted) {
      _tickTimer?.cancel();
      _tickTimer = null;
      if (!_disposed) progressTick.notifyListeners();
    }
  }

  Future<void> _refreshQueue() async {
    try {
      _queue = await _api.queue();
    } on SpotifyApiException catch (e) {
      _reportBackgroundFailure('queue', e);
    }
  }

  /// 裏で走る取得の失敗。普段は黙っているが、レート制限や権限まわりは
  /// 黙っていると「なぜか古いまま」にしか見えないのでバナーに出す。
  void _reportBackgroundFailure(String what, SpotifyApiException e) {
    debugPrint('$what fetch failed: $e');
    if (_isHardError(e)) _errorBanner = e.message;
  }

  /// キュー操作の直後だけ、反映を待ってから取り直す。
  /// Spotify 側の反映に少し遅れがあるので 1 テンポ置く。
  Future<void> _refreshQueueSoon() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed) return;
    await _refreshQueue();
    if (!_disposed) notifyListeners();
  }

  // ── UI 状態 ──────────────────────────────────────────────────────────

  void selectTab(RailTab value) {
    _tab = value;
    if (value != RailTab.queue) _sheetOpen = true;
    // 別のタブへ移ったら「追加先を選ぶ」は畳む。行の意味（再生 / 追加）が
    // 見えないところで変わったままになるのを防ぐ。
    if (value != RailTab.playlists) _addingTrack = null;
    if (value == RailTab.playlists && !_playlistsLoaded) {
      unawaited(loadPlaylists());
    }
    notifyListeners();
  }

  void toggleSheet() {
    _sheetOpen = !_sheetOpen;
    if (!_sheetOpen) _addingTrack = null;
    notifyListeners();
  }

  void openSheet(RailTab value) {
    _sheetOpen = true;
    selectTab(value);
  }

  void toggleDevicePopover() {
    if (_deviceLost) {
      _devicesOpen = false;
      notifyListeners();
      return;
    }
    _devicesOpen = !_devicesOpen;
    if (_devicesOpen) unawaited(refreshDevices(silent: true));
    notifyListeners();
  }

  void closeDevicePopover() {
    if (!_devicesOpen) return;
    _devicesOpen = false;
    notifyListeners();
  }

  void dismissNoDevice() {
    _deviceLost = false;
    notifyListeners();
  }

  void dismissError() {
    _errorBanner = null;
    notifyListeners();
  }

  void showToast(String text) {
    _toast = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (_disposed) return;
      _toast = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // ── デバイス ─────────────────────────────────────────────────────────

  /// 本当の名前が付いているものを覚え、名前を失っているものには当て直す。
  ///
  /// Connect スピーカーは公式クライアントに登録されるまで name が識別子で
  /// 返ってくる（`SpotifyDevice.looksLikeIdentifier`）。一度でも名前が取れた
  /// なら以降はそれを出す。初回だけは Unknown device のままになる。
  List<SpotifyDevice> _applyCachedNames(List<SpotifyDevice> devices) {
    var learned = false;
    for (final device in devices) {
      final id = device.id;
      final name = device.realName;
      if (id == null || name == null || _deviceNames[id] == name) continue;
      _deviceNames.remove(id); // 挿入順を「最後に覚えた順」に保つ
      _deviceNames[id] = name;
      learned = true;
    }
    if (learned) unawaited(_deviceNameCache?.save(_deviceNames) ?? Future.value());
    return devices.map(_applyCachedName).toList(growable: false);
  }

  SpotifyDevice _applyCachedName(SpotifyDevice device) {
    if (device.realName != null) return device;
    final cached = _deviceNames[device.id];
    return cached == null ? device : device.withName(cached);
  }

  Future<void> refreshDevices({bool silent = false}) async {
    try {
      _devices = _applyCachedNames(await _api.devices());
      // アイドル中の WiiM は一覧に出てこないことがある（設計メモ §9）。
      // 「出力できる先が 1 つも無い」ときだけデバイス消失として扱う。
      final playable = _devices.where((d) => !d.isRestricted && d.id != null);
      if (playable.isEmpty) {
        _deviceLost = true;
      } else if (!silent) {
        _deviceLost = false;
      }
      if (_preferredDeviceId != null &&
          !_devices.any((d) => d.id == _preferredDeviceId)) {
        _preferredDeviceId = null;
      }
    } on SpotifyApiException catch (e) {
      _reportBackgroundFailure('devices', e);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> rescanDevices() async {
    _devicesOpen = false;
    _deviceLost = false;
    notifyListeners();
    await refreshDevices();
    if (_deviceLost) {
      showToast('デバイスが見つかりませんでした');
    } else {
      showToast('$deviceLabel が見つかりました');
      await _pollOnce();
    }
  }

  Future<void> pickDevice(SpotifyDevice device) async {
    _devicesOpen = false;
    final id = device.id;
    if (id == null || device.isRestricted) {
      showToast('このデバイスは操作できません');
      notifyListeners();
      return;
    }
    _preferredDeviceId = id;
    notifyListeners();
    await _guard(() async {
      // 停止中に転送すると鳴り出してしまうので、再生中だけ play: true。
      await _api.transfer(id, play: isPlaying);
      showToast('${device.name} に転送しました');
    });
    await _pollOnce();
  }

  // ── 再生操作 ─────────────────────────────────────────────────────────

  Future<void> togglePlayPause() async {
    if (_deviceLost) {
      showToast('デバイスが見つかりません');
      return;
    }
    if (isStopped) {
      // 復帰ロジックは持たない（設計メモ §5）。曲を入れてもらう導線に寄せる。
      openSheet(RailTab.search);
      return;
    }
    final wasPlaying = _playback.isPlaying;
    // 押した瞬間に見た目を変える。次のポーリングで真の状態に上書きされる。
    _playback = PlaybackState(
      isPlaying: !wasPlaying,
      progressMs: position.inMilliseconds,
      shuffleState: _playback.shuffleState,
      hasContent: true,
      track: _playback.track,
      device: _playback.device,
      contextUri: _playback.contextUri,
    );
    _playbackFetchedAt = _now();
    _syncTicker();
    notifyListeners();
    await _guard(() =>
        wasPlaying ? _api.pause() : _api.resume(deviceId: _targetDeviceId));
  }

  Future<void> skipNext() async {
    if (_deviceLost) return;
    // キューの先頭が分かっているなら、返事を待たずにそこへ進めてしまう。
    final target = nextTrack;
    final undo = _beginOptimisticSkip(
      target,
      queue: _queue.upcoming.length > 1
          ? QueueSnapshot(upcoming: _queue.upcoming.sublist(1))
          : QueueSnapshot.empty,
      pushCurrentToHistory: true,
    );
    if (!await _guard(_api.next)) {
      _undoOptimisticSkip(undo);
      return;
    }
    await _afterCommand();
  }

  Future<void> skipPrevious() async {
    if (_deviceLost) return;
    // 履歴があるときだけ先に戻す。無ければ従来どおり結果を待つ。
    final target = _history.isEmpty ? null : _history.last;
    final undo = _beginOptimisticSkip(
      target,
      // 戻ると今の曲がキューの先頭に来る。真の並びは次のポーリングで入れ替わる。
      queue: target == null
          ? _queue
          : QueueSnapshot(
              upcoming: [?currentTrack, ..._queue.upcoming],
            ),
      popHistory: true,
    );
    if (!await _guard(_api.previous)) {
      _undoOptimisticSkip(undo);
      return;
    }
    await _afterCommand();
  }

  /// 曲送りの見た目だけ先に進める。[target] が null なら何もしない。
  /// 戻り値は取り消し用のスナップショット。
  _SkipUndo? _beginOptimisticSkip(
    Track? target, {
    required QueueSnapshot queue,
    bool pushCurrentToHistory = false,
    bool popHistory = false,
  }) {
    if (target == null || isStopped) return null;
    final undo = _SkipUndo(
      playback: _playback,
      fetchedAt: _playbackFetchedAt,
      queue: _queue,
      staleUri: _staleUri,
      skipUntil: _skipUntil,
      history: List.of(_history),
    );

    if (pushCurrentToHistory) _pushHistory(currentTrack);
    if (popHistory && _history.isNotEmpty) _history.removeLast();

    _staleUri = currentTrack?.uri;
    // 反映がここまでに来なければ諦めて真の状態に従う。
    _skipUntil = _now().add(const Duration(seconds: 5));
    _playback = PlaybackState(
      isPlaying: true,
      progressMs: 0,
      shuffleState: _playback.shuffleState,
      hasContent: true,
      track: target,
      device: _playback.device,
      contextUri: _playback.contextUri,
    );
    _playbackFetchedAt = _now();
    _queue = queue;
    _lastQueueKey = target.uri;
    _boundaryRetries = 0;
    unawaited(_updatePalette(target));
    _syncTicker();
    notifyListeners();
    return undo;
  }

  /// 送りに失敗したときの巻き戻し。エラー自体は [_guard] がバナーに出す。
  void _undoOptimisticSkip(_SkipUndo? undo) {
    if (undo == null) return;
    _playback = undo.playback;
    _playbackFetchedAt = undo.fetchedAt;
    _queue = undo.queue;
    _staleUri = undo.staleUri;
    _skipUntil = undo.skipUntil;
    _history
      ..clear()
      ..addAll(undo.history);
    _lastQueueKey = undo.playback.track?.uri;
    unawaited(_updatePalette(undo.playback.track));
    _syncTicker();
    notifyListeners();
  }

  /// 先に出した次の曲より、返ってきた状態のほうが古いか。
  bool _isStaleAfterSkip(PlaybackState state) {
    final until = _skipUntil;
    if (until == null) return false;
    if (!_now().isBefore(until)) return false;
    // 送る前の曲がそのまま返っている間だけ待つ。別の曲になっていれば
    // 他のクライアントからの操作なので、素直に従う。
    return state.track?.uri != null && state.track?.uri == _staleUri;
  }

  void _pushHistory(Track? track) {
    if (track == null) return;
    if (_history.isNotEmpty && _history.last.uri == track.uri) return;
    _history.add(track);
    if (_history.length > _historyLimit) _history.removeAt(0);
  }

  /// ポーリングで曲が変わっていたら、鳴り終わったほうを履歴に積む。
  void _pushHistoryIfChanged(Track? incoming) {
    if (incoming?.uri == _playback.track?.uri) return;
    _pushHistory(_playback.track);
  }

  Future<void> setShuffle(bool value) async {
    await _guard(() => _api.setShuffle(value, deviceId: _targetDeviceId));
    await _pollOnce();
    // シャッフルは context 側の順序を変えるのでキューを取り直す。
    unawaited(_refreshQueueSoon());
  }

  /// 「次に再生へ追加」。パーティキューは FIFO で、シャッフルの影響を受けない
  /// （設計メモ §3）。
  Future<void> addToQueue(Track track) async {
    final ok = await _guard(
      () => _api.addToQueue(track.uri, deviceId: _targetDeviceId),
    );
    if (!ok) return;
    showToast('「${track.name}」をキューに追加しました');
    unawaited(_refreshQueueSoon());
  }

  /// 「今すぐ再生」。既存のキューと context は消える（設計メモ §5）。
  Future<void> playNow(Track track) async {
    final ok = await _guard(
      () => _api.playTrackNow(track.uri, deviceId: _targetDeviceId),
    );
    if (!ok) return;
    showToast('「${track.name}」を再生します');
    await _afterCommand();
  }

  /// 新譜のアルバムを base にして流す（設計メモ §14）。
  ///
  /// プレイリストと同じく context の差し替えなので、既存のキューは消える。
  /// アルバムは曲順に意味があることが多いのでシャッフルは触らない。
  Future<void> playAlbum(SpotifyAlbumMatch album) async {
    final ok = await _guard(
      () => _api.playContext(album.uri, deviceId: _targetDeviceId),
    );
    if (!ok) return;
    _tab = RailTab.queue;
    showToast('${album.name} を再生します');
    await _afterCommand();
  }

  Future<void> playPlaylist(PlaylistSummary playlist, {bool? shuffle}) async {
    final ok = await _guard(() async {
      // シャッフルは context を差し替える前に確定させる。逆順だと
      // 1 曲目の選ばれ方が変わってしまう。
      if (shuffle != null && shuffle != _playback.shuffleState) {
        await _api.setShuffle(shuffle, deviceId: _targetDeviceId);
      }
      await _api.playContext(playlist.uri, deviceId: _targetDeviceId);
    });
    if (!ok) return;
    _tab = RailTab.queue;
    showToast('${playlist.name} を再生します');
    await _afterCommand();
  }

  Future<void> _afterCommand() async {
    // 反映まで少し待たないと直前の状態を読んでしまう。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_disposed) return;
    _lastQueueKey = null; // 次の poll でキューも取り直させる
    await _pollOnce();
  }

  /// 書き込み系の共通ハンドリング。成功したら true。
  Future<bool> _guard(Future<void> Function() action) async {
    try {
      await action();
      _errorBanner = null;
      return true;
    } on NoActiveDeviceException {
      _deviceLost = true;
      _devicesOpen = false;
      notifyListeners();
      return false;
    } on SpotifyAuthExpiredException {
      return false;
    } on SpotifyApiException catch (e) {
      _errorBanner = e.message;
      notifyListeners();
      return false;
    }
  }

  // ── 検索 ─────────────────────────────────────────────────────────────

  void onQueryChanged(String value) {
    _query = value;
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      _results = const [];
      _searchHasMore = false;
      _searchBusy = false;
      notifyListeners();
      return;
    }
    _searchBusy = true;
    notifyListeners();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_runSearch(reset: true));
    });
  }

  /// リストの末尾に近づいたら次の 10 件を足す（limit 上限が 10 のため）。
  Future<void> loadMoreResults() async {
    if (_searchBusy || !_searchHasMore) return;
    await _runSearch(reset: false);
  }

  Future<void> _runSearch({required bool reset}) async {
    final generation = ++_searchGeneration;
    final term = _query.trim();
    if (term.isEmpty) return;
    _searchBusy = true;
    if (reset) _searchOffset = 0;
    notifyListeners();
    try {
      final page = await _api.searchTracks(term, offset: _searchOffset);
      // 打鍵が進んで別の検索が始まっていたら、古い結果は捨てる。
      if (_disposed || generation != _searchGeneration) return;
      _results = reset ? page.tracks : [..._results, ...page.tracks];
      _searchOffset = page.offset + page.tracks.length;
      _searchHasMore = page.hasMore;
    } on SpotifyApiException catch (e) {
      if (_disposed || generation != _searchGeneration) return;
      _errorBanner = e.message;
    } finally {
      if (!_disposed && generation == _searchGeneration) {
        _searchBusy = false;
        notifyListeners();
      }
    }
  }

  // ── プレイリスト ──────────────────────────────────────────────────────

  Future<void> loadPlaylists() async {
    try {
      _playlists = await _api.playlists();
      _playlistsLoaded = true;
    } on SpotifyApiException catch (e) {
      _reportBackgroundFailure('playlists', e);
    }
    if (!_disposed) notifyListeners();
  }

  /// 自分の Spotify user id。プレイリストを編集できるかの判定だけに使う。
  /// 取れなければ null のまま（全リストを編集可として扱う）。
  Future<void> _loadUserId() async {
    try {
      final id = await _api.currentUserId();
      if (_disposed || id == null) return;
      _userId = id;
      notifyListeners();
    } on SpotifyApiException catch (e) {
      debugPrint('currentUserId failed: $e');
    }
  }

  bool canEdit(PlaylistSummary playlist) => playlist.isEditableBy(_userId);

  /// 曲を足せるプレイリストだけ。他人のリスト（フォロー中）を落とす。
  List<PlaylistSummary> get editablePlaylists =>
      _playlists.where(canEdit).toList(growable: false);

  /// 一覧から落とした（＝編集できない）リストの数。
  int get readOnlyPlaylistCount => _playlists.length - editablePlaylists.length;

  /// 今の曲が「入っていると確実に言える」プレイリスト。
  ///
  /// **Spotify には「この曲を含むプレイリスト」を返す API が無い。** 全リストの
  /// 中身を舐めれば分かるが数十リクエストになる。0 リクエストで確実に言えるのは
  /// 再生元（context）だけなので、判定をそこに限っている。手元の一覧に無い
  /// context（他人の公開リスト・エディトリアル）や、編集できないものは null。
  PlaylistSummary? get currentTrackPlaylist {
    if (currentTrack == null) return null;
    final uri = _playback.contextUri;
    if (uri == null || !uri.startsWith('spotify:playlist:')) return null;
    for (final playlist in _playlists) {
      if (playlist.uri == uri) return canEdit(playlist) ? playlist : null;
    }
    return null;
  }

  /// 「追加先を選ぶ」モードで押された曲。null なら通常モード。
  ///
  /// 選んでいる間に曲が変わっても、押した時点の曲を足したい。だから
  /// [currentTrack] を見ずにここへ留めておく。
  Track? get addingTrack => _addingTrack;

  /// 追加先の選択を始める。プレイリストのタブを開くだけで、まだ何も書かない。
  void beginAddToPlaylist(Track track) {
    if (!_playlistsLoaded) unawaited(loadPlaylists());
    // openSheet → selectTab の中で notifyListeners まで走る。
    // playlists 以外のタブへ移ると _addingTrack は落ちるので順序は変えない。
    _addingTrack = track;
    openSheet(RailTab.playlists);
  }

  void cancelAddToPlaylist() {
    if (_addingTrack == null) return;
    _addingTrack = null;
    notifyListeners();
  }

  /// プレイリストを書き換える scope を持っていないなら、叩かずに理由を出す。
  ///
  /// `/playlists/*` の 403 は Spotify が素の "Forbidden" しか返さないので、
  /// そのまま出すと何をすればいいのか分からない。手元で足りないと分かっている
  /// ぶんは、リクエストを使わずにここで言い切る。
  bool _blockedByMissingScope() {
    const writeScopes = {'playlist-modify-public', 'playlist-modify-private'};
    if (!_api.missingScopes.any(writeScopes.contains)) return false;
    // どこを押せばいいのかまで書く。バナー（ReauthBanner）は控えの scope が
    // 足りないと分かっているときしか出ないので、そこに頼らせない。
    _errorBanner = 'プレイリストの変更には Spotify との再連携が必要です（☰ → SPOTIFY と再連携）';
    notifyListeners();
    return true;
  }

  Future<void> addToPlaylist(PlaylistSummary playlist, Track track) async {
    // 選び直しからやらせたいので、弾くのは選択を畳む前。
    if (_blockedByMissingScope()) return;
    // 選択は押した時点で終わり。失敗しても選び直しからやらせる。
    _addingTrack = null;
    notifyListeners();
    final ok = await _guard(
      () => _api.addTrackToPlaylist(playlist.id, track.uri),
    );
    if (!ok) return;
    _bumpTrackCount(playlist, 1);
    showToast('「${track.name}」を ${playlist.name} に追加しました');
    _refreshQueueIfContext(playlist);
  }

  Future<void> removeFromPlaylist(PlaylistSummary playlist, Track track) async {
    if (_blockedByMissingScope()) return;
    final ok = await _guard(
      () => _api.removeTrackFromPlaylist(playlist.id, track.uri),
    );
    if (!ok) return;
    _bumpTrackCount(playlist, -1);
    showToast('「${track.name}」を ${playlist.name} から削除しました');
    _refreshQueueIfContext(playlist);
  }

  /// 触ったのが今流しているリストなら、この先の並びが変わっている。
  /// 鳴っている曲自体は消しても止まらない（Spotify 側の挙動）。
  void _refreshQueueIfContext(PlaylistSummary playlist) {
    if (_playback.contextUri == playlist.uri) unawaited(_refreshQueueSoon());
  }

  /// 一覧の "42 songs" を手元で合わせる。取り直しの 1 リクエストを省くだけ。
  void _bumpTrackCount(PlaylistSummary playlist, int delta) {
    final index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index < 0) return;
    final updated = [..._playlists];
    updated[index] = updated[index].withTrackCount(
      updated[index].trackCount + delta,
    );
    _playlists = updated;
    notifyListeners();
  }

  // ── 配色抽出 ─────────────────────────────────────────────────────────

  Future<void> _updatePalette(Track? track) async {
    final url = track?.artworkUrl;
    if (url == null || url == _paletteSourceUrl) return;
    _paletteSourceUrl = url;
    try {
      final generated = await PaletteGenerator.fromImageProvider(
        NetworkImage(url),
        size: const ui.Size(120, 120),
        maximumColorCount: 12,
      );
      if (_disposed || _paletteSourceUrl != url) return;
      final accent =
          generated.vibrantColor?.color ??
          generated.lightVibrantColor?.color ??
          generated.dominantColor?.color ??
          ArtworkPalette.fallback.accent;
      final deep =
          generated.darkMutedColor?.color ??
          generated.darkVibrantColor?.color ??
          _darken(accent);
      _palette = ArtworkPalette(deep, accent);
      notifyListeners();
    } catch (e) {
      // 画像が取れないだけなので既定色で続行する。
      debugPrint('palette extraction failed: $e');
    }
  }

  Color _darken(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness * 0.35).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0))
        .toColor();
  }
}

/// 曲送りを先に画面へ出す前の状態。失敗したらここへ戻す。
class _SkipUndo {
  const _SkipUndo({
    required this.playback,
    required this.fetchedAt,
    required this.queue,
    required this.staleUri,
    required this.skipUntil,
    required this.history,
  });

  final PlaybackState playback;
  final DateTime fetchedAt;
  final QueueSnapshot queue;
  final String? staleUri;
  final DateTime? skipUntil;
  final List<Track> history;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
