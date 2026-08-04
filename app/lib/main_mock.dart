// 実データ無しでデザインを見るためのブラウザ用エントリポイント。
//
//   make app-mock                 Chrome で開く（上部バーで枠を切り替える）
//   make app-mock DEVICE=iphone   iPhone サイズの枠で開く（ipad も可）
//
// Spotify にはつながない。AuthService / SpotifyApi をこのファイル内の偽物に
// 差し替えているだけで、画面もポーリングも状態遷移も本番と同じコードが動く。
// 再生位置は時計で進み、再生/停止・曲送り・キュー追加・検索・デバイス切り替えは
// すべて手元の状態を書き換えて返すので、触った結果がそのまま画面に出る。
//
// アートワークは web/mock/*.png。同一オリジンなので CORS に引っかからず、
// palette_generator の背景色抽出（PlayerController._updatePalette）も通る。

import 'dart:async';

import 'package:flutter/material.dart';

import 'models/release_models.dart';
import 'models/spotify_models.dart';
import 'services/auth_service.dart';
import 'services/musicbrainz_api.dart';
import 'services/spotify_api.dart';
import 'state/new_releases_controller.dart';
import 'state/player_controller.dart';
import 'theme/tokens.dart';
import 'ui/controller_screen.dart';
import 'ui/login_screen.dart';

void main() {
  runApp(const MockApp());
}

/// 表示枠。実機の論理サイズとセーフエリアを模す。
enum _Stage {
  fit('Fit', null, EdgeInsets.zero, 0),
  iphone('iPhone', Size(390, 844), EdgeInsets.only(top: 47, bottom: 34), 46),
  ipad('iPad', Size(1194, 834), EdgeInsets.only(top: 24, bottom: 20), 26);

  const _Stage(this.label, this.size, this.padding, this.radius);

  final String label;

  /// null なら「ブラウザのウィンドウいっぱい」。
  final Size? size;
  final EdgeInsets padding;
  final double radius;
}

const double _barHeight = 30;

class MockApp extends StatefulWidget {
  const MockApp({super.key});

  @override
  State<MockApp> createState() => _MockAppState();
}

class _MockAppState extends State<MockApp> {
  late final _MockAuth _auth = _MockAuth();
  late final _MockApi _api = _MockApi(_auth);
  late final _MockMusicBrainz _musicBrainz = _MockMusicBrainz();
  late final NewReleasesController _newReleases = NewReleasesController(
    _api,
    _musicBrainz,
  );

  /// 起動時は ?device=iphone / ?device=ipad を見る。無ければウィンドウ追従。
  _Stage _stage = _Stage.values.firstWhere(
    (s) => s.name == Uri.base.queryParameters['device'],
    orElse: () => _Stage.fit,
  );

  /// サインアウトするたびに作り直す（main.dart と同じ扱い）。
  PlayerController? _player;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_syncPlayer);
    // 最初からサインイン済みで始める。initState では setState を呼べないので直接。
    _player = PlayerController(_api);
  }

  @override
  void dispose() {
    _auth.removeListener(_syncPlayer);
    _player?.dispose();
    _auth.dispose();
    super.dispose();
  }

  void _syncPlayer() {
    final signedIn = _auth.isSignedIn;
    if (signedIn && _player == null) {
      setState(() => _player = PlayerController(_api));
    } else if (!signedIn && _player != null) {
      final old = _player;
      setState(() => _player = null);
      old?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotify Remote — mock',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => ColoredBox(
          color: const Color(0xFF08080B),
          child: Column(
            children: [
              _DevBar(stage: _stage, onPick: (s) => setState(() => _stage = s)),
              Expanded(child: _staged(_screen())),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screen() {
    return ListenableBuilder(
      listenable: _auth,
      builder: (context, _) {
        final player = _player;
        if (player == null) return LoginScreen(auth: _auth);
        return ControllerScreen(
          key: ValueKey(player),
          controller: player,
          newReleases: _newReleases,
          resolver: ReleaseResolver(_api),
          onSignOut: _auth.signOut,
        );
      },
    );
  }

  /// 枠に入れる。MediaQuery も端末のサイズ/セーフエリアで上書きするので、
  /// ブレークポイント（kTabletBreakpoint）も SafeArea も実機と同じ判定になる。
  Widget _staged(Widget child) {
    final size = _stage.size;
    if (size == null) {
      return LayoutBuilder(
        builder: (context, constraints) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: constraints.biggest,
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
          ),
          child: child,
        ),
      );
    }
    return Center(
      // ウィンドウが枠より小さいときは、はみ出させずに縮めて全体を見せる。
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: size,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_stage.radius),
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: size,
                  padding: _stage.padding,
                  viewPadding: _stage.padding,
                  viewInsets: EdgeInsets.zero,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 枠の切り替えと、いま何 pt でどちらのレイアウトかの表示だけ。
class _DevBar extends StatelessWidget {
  const _DevBar({required this.stage, required this.onPick});

  final _Stage stage;
  final ValueChanged<_Stage> onPick;

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final size =
        stage.size ?? Size(window.width, (window.height - _barHeight).abs());
    final layout = size.width >= kTabletBreakpoint ? 'tablet' : 'phone';

    return SizedBox(
      height: _barHeight,
      child: ColoredBox(
        color: const Color(0xFF121218),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Text(
              'MOCK',
              style: TextStyle(
                fontSize: 10,
                height: 1,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w700,
                color: AppColors.green,
              ),
            ),
            const SizedBox(width: 14),
            for (final s in _Stage.values) ...[
              _Chip(label: s.label, on: s == stage, onTap: () => onPick(s)),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            Text(
              '${size.width.round()} × ${size.height.round()} · $layout',
              style: TextStyle(
                fontSize: 11,
                height: 1,
                color: AppColors.white(0.45),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: on ? AppColors.green : AppColors.white(0.07),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w600,
            color: on ? const Color(0xFF08130C) : AppColors.white(0.65),
          ),
        ),
      ),
    );
  }
}

// ── 偽物のサインイン ─────────────────────────────────────────────────────

/// Keychain も PKCE も使わない。ログイン画面を見るためだけの張りぼて。
class _MockAuth extends AuthService {
  bool _signedIn = true;
  bool _busy = false;

  @override
  bool get isRestored => true;

  @override
  bool get isSignedIn => _signedIn;

  @override
  bool get isBusy => _busy;

  @override
  String? get error => null;

  @override
  Future<void> restore() async {}

  @override
  Future<bool> signIn() async {
    _busy = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _busy = false;
    _signedIn = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> signOut() async {
    _signedIn = false;
    notifyListeners();
  }
}

// ── 偽物の Web API ───────────────────────────────────────────────────────

Track _track(
  String id,
  String name,
  String artists,
  String album,
  int seconds,
  int art,
) {
  return Track(
    id: id,
    uri: 'spotify:track:$id',
    name: name,
    artists: artists,
    albumName: album,
    durationMs: seconds * 1000,
    artworkUrl: 'mock/art-$art.png',
    smallArtworkUrl: 'mock/art-$art.png',
  );
}

/// 再生中のプレイリスト分。ここが順番に流れる。
final List<Track> _library = [
  _track('t1', 'Midnight City', 'M83', "Hurry Up, We're Dreaming", 243, 1),
  _track(
    't2',
    'Get Lucky',
    'Daft Punk, Pharrell Williams, Nile Rodgers',
    'Random Access Memories',
    369,
    2,
  ),
  _track('t3', 'Blinding Lights', 'The Weeknd', 'After Hours', 200, 3),
  _track('t4', 'Redbone', 'Childish Gambino', 'Awaken, My Love!', 326, 4),
  _track('t5', '夜に駆ける', 'YOASOBI', 'THE BOOK', 261, 5),
  // 長いタイトル: 1 行固定の横流し（MarqueeText）を確認するため。
  _track('t6', 'Everything In Its Right Place', 'Radiohead', 'Kid A', 251, 6),
  _track('t7', '打上花火', 'DAOKO, 米津玄師', '打上花火', 290, 7),
  _track(
    't8',
    'Doo Wop (That Thing)',
    'Ms. Lauryn Hill',
    'The Miseducation of Lauryn Hill',
    320,
    8,
  ),
];

/// 検索で引っかかる分。ライブラリ + 検索でしか出てこない曲。
final List<Track> _catalog = [
  ..._library,
  _track(
    's1',
    'Instant Crush',
    'Daft Punk, Julian Casablancas',
    'Random Access Memories',
    337,
    2,
  ),
  _track('s2', 'Save Your Tears', 'The Weeknd', 'After Hours', 215, 3),
  _track('s3', 'Feel Good Inc.', 'Gorillaz', 'Demon Days', 221, 1),
  _track('s4', 'Weird Fishes / Arpeggi', 'Radiohead', 'In Rainbows', 318, 6),
  _track('s5', 'アイドル', 'YOASOBI', 'アイドル', 214, 5),
  _track('s6', 'Pyramids', 'Frank Ocean', 'channel ORANGE', 593, 4),
  _track('s7', 'Sunday Morning', 'Maroon 5', 'Songs About Jane', 244, 8),
  _track('s8', 'Tokyo', 'Cero', 'Obscure Ride', 268, 7),
];

const _deviceSpecs = [
  ('wiim', 'WiiM Ultra', SpotifyDeviceKind.speaker, 42),
  ('tv', 'リビングの TV', SpotifyDeviceKind.tv, 30),
  ('mac', 'MacBook Pro', SpotifyDeviceKind.computer, 12),
  ('iphone', 'taiki の iPhone', SpotifyDeviceKind.smartphone, 78),
];

final List<PlaylistSummary> _playlists = [
  const PlaylistSummary(
    id: 'p1',
    uri: 'spotify:playlist:p1',
    name: 'Party 2026',
    ownerName: 'You',
    trackCount: 84,
    artworkUrl: 'mock/pl-1.png',
  ),
  const PlaylistSummary(
    id: 'p2',
    uri: 'spotify:playlist:p2',
    name: '日曜の朝',
    ownerName: 'Taiki',
    trackCount: 42,
    artworkUrl: 'mock/pl-2.png',
  ),
  const PlaylistSummary(
    id: 'p3',
    uri: 'spotify:playlist:p3',
    name: 'Late Night Drive',
    ownerName: 'Taiki',
    trackCount: 120,
    artworkUrl: 'mock/pl-3.png',
  ),
  const PlaylistSummary(
    id: 'p4',
    uri: 'spotify:playlist:p4',
    name: 'ごはんのとき',
    ownerName: 'みんな',
    trackCount: 57,
    artworkUrl: 'mock/pl-4.png',
  ),
];

/// 手元に再生状態を持つ SpotifyApi。読みは 60ms、書きは 160ms 遅らせて、
/// 実機と同じように「押してから反映されるまで」の間を作る。
class _MockApi extends SpotifyApi {
  _MockApi(super.auth);

  Track _current = _library.first;
  final List<Track> _upcoming = _library.skip(1).toList();
  final List<Track> _history = [];
  int _fill = 0;

  bool _playing = true;
  bool _shuffle = false;
  String _activeDeviceId = 'wiim';
  String? _contextUri = 'spotify:playlist:p1';

  /// 進捗は「最後に置いた位置 + それからの経過」で作る。
  int _baseMs = 62000;
  DateTime _basedAt = DateTime.now();

  Future<void> _read() =>
      Future<void>.delayed(const Duration(milliseconds: 60));
  Future<void> _write() =>
      Future<void>.delayed(const Duration(milliseconds: 160));

  int get _progressMs => _playing
      ? _baseMs + DateTime.now().difference(_basedAt).inMilliseconds
      : _baseMs;

  void _seek(int ms) {
    _baseMs = ms;
    _basedAt = DateTime.now();
  }

  /// 曲の終わりまで来ていたら次へ送る（実際に流れている風にする）。
  void _settle() {
    var guard = 0;
    while (_playing && _progressMs >= _current.durationMs && guard++ < 8) {
      final over = _progressMs - _current.durationMs;
      _advance();
      _seek(over);
    }
  }

  void _advance() {
    _history.add(_current);
    _current = _upcoming.isEmpty ? _library.first : _upcoming.removeAt(0);
    _refill();
  }

  void _refill() {
    while (_upcoming.length < 6) {
      _upcoming.add(_library[_fill++ % _library.length]);
    }
  }

  Track? _find(String uri) {
    for (final t in _catalog) {
      if (t.uri == uri) return t;
    }
    return null;
  }

  List<SpotifyDevice> get _devices => [
    for (final (id, name, kind, volume) in _deviceSpecs)
      SpotifyDevice(
        id: id,
        name: name,
        kind: kind,
        isActive: id == _activeDeviceId,
        isRestricted: false,
        volumePercent: volume,
      ),
  ];

  @override
  Future<PlaybackState> playbackState() async {
    await _read();
    _settle();
    return PlaybackState(
      isPlaying: _playing,
      progressMs: _progressMs.clamp(0, _current.durationMs),
      shuffleState: _shuffle,
      hasContent: true,
      track: _current,
      device: _devices.firstWhere((d) => d.id == _activeDeviceId),
      contextUri: _contextUri,
    );
  }

  @override
  Future<QueueSnapshot> queue() async {
    await _read();
    _settle();
    return QueueSnapshot(upcoming: List.of(_upcoming));
  }

  @override
  Future<List<SpotifyDevice>> devices() async {
    await _read();
    return _devices;
  }

  @override
  Future<List<PlaylistSummary>> playlists({int limit = 50}) async {
    await _read();
    return List.of(_playlists);
  }

  @override
  Future<SearchPage> searchTracks(String query, {int offset = 0}) async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    final q = query.trim().toLowerCase();
    final hits = _catalog
        .where(
          (t) =>
              t.name.toLowerCase().contains(q) ||
              t.artists.toLowerCase().contains(q) ||
              t.albumName.toLowerCase().contains(q),
        )
        .toList();
    // ページングと「もっと読む」を出すため、わざと小さく刻む。
    final slice = hits.skip(offset).take(6).toList();
    return SearchPage(
      tracks: slice,
      offset: offset,
      hasMore: offset + slice.length < hits.length,
    );
  }

  @override
  Future<void> resume({String? deviceId}) async {
    await _write();
    _seek(_baseMs);
    _playing = true;
  }

  @override
  Future<void> pause() async {
    await _write();
    final at = _progressMs;
    _playing = false;
    _seek(at);
  }

  @override
  Future<void> next() async {
    await _write();
    _settle();
    _advance();
    _seek(0);
  }

  @override
  Future<void> previous() async {
    await _write();
    // Spotify と同じで、3 秒以上流れていたら頭出しに使う。
    if (_progressMs > 3000 || _history.isEmpty) {
      _seek(0);
      return;
    }
    _upcoming.insert(0, _current);
    _current = _history.removeLast();
    _seek(0);
  }

  @override
  Future<void> setShuffle(bool on, {String? deviceId}) async {
    await _write();
    _shuffle = on;
  }

  @override
  Future<void> addToQueue(String trackUri, {String? deviceId}) async {
    await _write();
    final track = _find(trackUri);
    if (track != null) _upcoming.insert(0, track);
  }

  @override
  Future<void> playTrackNow(String trackUri, {String? deviceId}) async {
    await _write();
    final track = _find(trackUri);
    if (track == null) return;
    _history.add(_current);
    _current = track;
    _playing = true;
    _seek(0);
  }

  @override
  Future<void> playContext(String contextUri, {String? deviceId}) async {
    await _write();
    _contextUri = contextUri;
    // プレイリストごとに始まる曲を変えて、切り替わったことが分かるようにする。
    final start = _playlists.indexWhere((p) => p.uri == contextUri);
    _fill = start < 0 ? 0 : start * 2;
    _upcoming.clear();
    _refill();
    _history.add(_current);
    _current = _upcoming.removeAt(0);
    _refill();
    _playing = true;
    _seek(0);
  }

  @override
  Future<void> transfer(String deviceId, {bool play = true}) async {
    await _write();
    final at = _progressMs;
    _activeDeviceId = deviceId;
    _playing = play;
    _seek(at);
  }
}

/// 新譜まわりの偽物。ネットワークに出ずに「New」タブの見た目を確認するためだけ。
/// ジャケットは web/mock を使うので Cover Art Archive にも出ない。
class _MockMusicBrainz extends MusicBrainzApi {
  @override
  Future<Map<String, String>> artistMbidsBySpotifyUrl(
    List<String> spotifyUrls,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 240));
    // わざと 1 組だけ解決できないことにして、カバー率の表示を確認できるようにする。
    final resolved = spotifyUrls.take(spotifyUrls.length - 1);
    return {
      for (final (index, url) in resolved.indexed) url: 'mbid-artist-$index',
    };
  }

  @override
  Future<List<NewRelease>> releaseGroups({
    required List<String> artistMbids,
    required DateTime from,
    required DateTime to,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 320));
    final today = DateTime.now();
    NewRelease make(String title, String artist, int offsetDays, int art) =>
        NewRelease(
          releaseGroupMbid: 'mock-${title.hashCode}',
          title: title,
          artistName: artist,
          artistMbids: const ['mbid-artist-0'],
          releaseDate: DateTime(
            today.year,
            today.month,
            today.day,
          ).add(Duration(days: offsetDays)),
          primaryType: 'Album',
        );
    return [
      make('Melting Days', 'Lusine', 17, 1),
      make('Sunshine', 'Jungle', 10, 2),
      make('II Reworked', 'Kiasmos', 3, 3),
      make('Frozen Charlotte', 'Jack White', -6, 4),
      make('A ? of WHEN', 'Panda Bear & Sonic Boom', -21, 1),
    ];
  }
}
