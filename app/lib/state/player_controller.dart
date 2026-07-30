import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:palette_generator/palette_generator.dart';

import '../models/spotify_models.dart';
import '../services/spotify_api.dart';
import '../theme/tokens.dart';

/// 右レール / ボトムシートのタブ。
enum RailTab { queue, search, playlists }

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
  PlayerController(this._api);

  final SpotifyApi _api;

  // ── Spotify から取ってきたもの ────────────────────────────────────────
  PlaybackState _playback = PlaybackState.stopped;
  DateTime _playbackFetchedAt = DateTime.now();
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
  String? _lastQueueKey;

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
    if (_playback.device != null) return _playback.device;
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
    final elapsed = DateTime.now().difference(_playbackFetchedAt);
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
    await refreshDevices(silent: true);
    await _pollOnce();
    unawaited(loadPlaylists());
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
      _playback = state;
      _playbackFetchedAt = DateTime.now();
      if (state.hasContent) {
        // 再生できているならデバイスは生きている。
        _deviceLost = false;
        _errorBanner = null;
      }
      unawaited(_updatePalette(state.track));

      // キューは「曲が変わったとき」だけ取り直す（設計メモ §8）。
      final key = state.track?.uri;
      if (key != _lastQueueKey) {
        _lastQueueKey = key;
        await _refreshQueue();
      }
      notifyListeners();
    } on SpotifyAuthExpiredException {
      // AuthService 側が既にサインアウト済み。ルートが Login に切り替わる。
      return;
    } on SpotifyApiException catch (e) {
      // ポーリングの失敗はうるさく出さない。429 だけ間隔で吸収する。
      if (e.statusCode != 429 && e.statusCode != 404) {
        debugPrint('poll failed: $e');
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
    final cooldown = _api.rateLimitCooldown;
    final interval = cooldown != null
        ? cooldown + const Duration(milliseconds: 250)
        : isPlaying
        ? const Duration(seconds: 1)
        : const Duration(seconds: 5);
    _pollTimer = Timer(interval, _pollOnce);
  }

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
      debugPrint('queue fetch failed: $e');
    }
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
    if (value == RailTab.playlists && !_playlistsLoaded) {
      unawaited(loadPlaylists());
    }
    notifyListeners();
  }

  void toggleSheet() {
    _sheetOpen = !_sheetOpen;
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

  Future<void> refreshDevices({bool silent = false}) async {
    try {
      _devices = await _api.devices();
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
      debugPrint('devices fetch failed: $e');
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
    _playbackFetchedAt = DateTime.now();
    _syncTicker();
    notifyListeners();
    await _guard(() =>
        wasPlaying ? _api.pause() : _api.resume(deviceId: _targetDeviceId));
  }

  Future<void> skipNext() async {
    if (_deviceLost) return;
    await _guard(_api.next);
    await _afterCommand();
  }

  Future<void> skipPrevious() async {
    if (_deviceLost) return;
    await _guard(_api.previous);
    await _afterCommand();
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
      debugPrint('playlists fetch failed: $e');
    }
    if (!_disposed) notifyListeners();
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
