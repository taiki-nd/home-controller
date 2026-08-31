import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/qobuz_models.dart';
import '../models/wiim_models.dart';
import '../services/qobuz_api.dart';
import '../services/qobuz_bundle.dart';
import '../services/qobuz_credentials.dart';
import '../services/playback_keepalive.dart';
import '../services/qobuz_web_login.dart';
import '../services/wiim_api.dart';
import '../services/wiim_credentials.dart';
import '../services/wiim_discovery.dart';
import '../services/wiim_upnp.dart';
import 'playback_surface.dart';

/// 画面が知りたい状態。
enum QobuzStatus {
  /// WiiM の IP か Qobuz のログインがまだ。設定画面へ。
  needsSetup,

  connecting,
  connected,

  /// Qobuz のトークンが切れた。**再ログインで直る。**
  authFailed,

  /// app_id / app_secret が拒否された。**再ログインでは直らない**（§3）。
  /// bundle.js から取り直す導線に倒す。
  keyFailed,

  /// WiiM に届かない。時間をおいて自動で繋ぎ直す。
  offline,
}

/// 下のタブ。**宣言順がそのまま表示順**で、music の `RailTab` と同じ並び
/// （Up next → Library → Add tracks）。New は QOBUZ に無いぶんが抜ける。
enum QobuzTab { queue, library, search }

/// キューへの積み方。
enum QobuzQueueOption {
  /// いま鳴っているものを止めて、これを鳴らす。
  play,

  /// キューを捨てて入れ替える。
  replace,

  /// 次の 1 曲として割り込ませる。
  next,

  /// 末尾に足す。
  add,
}

/// リピート。
enum QobuzRepeatMode {
  off,
  all,
  one;

  /// off → all → one → off。ボタン 1 つで回すため。
  QobuzRepeatMode get next => switch (this) {
    QobuzRepeatMode.off => QobuzRepeatMode.all,
    QobuzRepeatMode.all => QobuzRepeatMode.one,
    QobuzRepeatMode.one => QobuzRepeatMode.off,
  };
}

/// キューの 1 行。
///
/// **同じ曲を 2 回積めるので、行の同一性は曲 ID では決まらない。**
/// 削除と並べ替えのために行ごとの ID を振る。
@immutable
class QobuzQueueItem {
  const QobuzQueueItem({required this.id, required this.track});

  final int id;
  final QobuzTrack track;
}

/// ライブラリで開いている中身（プレイリスト / アルバム）。
@immutable
class QobuzListing {
  const QobuzListing({
    required this.title,
    required this.tracks,
    this.subtitle,
    this.imageUrl,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final List<QobuzTrack> tracks;
}

/// Qobuz を直に叩き、WiiM に投げる側の状態
/// （`docs/qobuz-wiim-integration.md` §7）。
///
/// **キューはこのアプリが持つ。** WiiM の HTTP API に「キューに追加」は無く
/// （公式コマンドは `play:url` と `hex_playlist` だけ、キュー操作は UPnP の
/// PlayQueue1 側）、署名付き URL は 24 時間で失効する。だから WiiM には
/// **1 曲ずつ URL を投げ、曲の終わりを見て次を送る**（§5.3 の方式 A）。
/// 次に再生・末尾に追加・並べ替え・削除がすべて手の内に入るのはこの形の利点。
class QobuzController extends ChangeNotifier implements PlaybackSurface {
  QobuzController({
    QobuzCredentials? credentials,
    WiimCredentials? wiimCredentials,
    QobuzApi? api,
    WiimApi? wiim,
    WiimDiscovery? discovery,
    PlaybackKeepAlive? keepAlive,
  }) : _credentials = credentials ?? QobuzCredentials(),
       _wiimCredentials = wiimCredentials ?? WiimCredentials(),
       _api = api ?? QobuzApi(),
       _wiim = wiim ?? WiimApi(),
       _discovery = discovery ?? WiimDiscovery(),
       _keepAlive = keepAlive ?? PlaybackKeepAlive();

  /// 再生中と停止中でポーリング間隔を変える（§7 M2）。
  /// 壁掛けでシークバーが動いて見えるのは再生中だけでよい。
  static const pollWhilePlaying = Duration(seconds: 1);
  static const pollWhileIdle = Duration(seconds: 5);

  /// バックグラウンドでの間隔（issue #8）。
  ///
  /// **シークバーを動かす必要が無い。** 誰も見ていないので、やることは
  /// 「本体がどこまで進んだか見て、次の 1 曲を預け直す」だけ。曲の長さに
  /// 対して 10 秒は十分細かい。
  static const pollWhileBackground = Duration(seconds: 10);

  /// 繋がらないときの間隔。頭打ちまで倍々。
  static const _retryMin = Duration(seconds: 2);
  static const _retryMax = Duration(seconds: 60);

  /// 検索を投げるまでの猶予。打ち終わる前に毎文字投げない。
  static const _searchDebounce = Duration(milliseconds: 450);

  /// `play` を送ってから「鳴っていない＝曲が終わった」と見なすまでの猶予。
  ///
  /// **これが無いと 1 曲目を送った直後に次へ飛ぶ。** WiiM は URL を掴んで
  /// バッファするまで `stop` のままなので、その間は終了と読まない。
  static const _startGrace = Duration(seconds: 8);

  /// トーストを出しておく時間。**music 側（`PlayerController.showToast`）と
  /// 同じ長さ。** 音源が変わっても同じ間で消えないと、消し忘れに見える。
  static const _toastDuration = Duration(seconds: 2);

  final QobuzCredentials _credentials;
  final WiimCredentials _wiimCredentials;
  final QobuzApi _api;
  final WiimApi _wiim;
  final WiimDiscovery _discovery;
  final PlaybackKeepAlive _keepAlive;

  QobuzAppConfig? _app;
  QobuzAccount? _account;
  WiimConnection? _wiimConnection;

  QobuzStatus _status = QobuzStatus.connecting;
  String? _error;
  String? _toast;
  bool _foreground = true;
  bool _disposed = false;
  bool _busy = false;

  Timer? _poll;
  Timer? _searchTimer;
  Timer? _toastTimer;
  Duration _backoff = _retryMin;

  WiimStatus? _wiimStatus;
  WiimDevice? _device;

  /// **Spotify 側と同じ絵作りにする**ため、抽出は共通のものを使う
  /// （`ArtworkPaletteResolver`）。ここが食い違うと、音源を切り替えたときに
  /// 同じ絵柄でも背景の印象が変わってしまう。
  final ArtworkPaletteResolver _paletteResolver = ArtworkPaletteResolver();

  List<WiimCandidate> _candidates = const [];
  bool _scanning = false;
  int _scanDone = 0;
  int _scanTotal = 0;

  final List<QobuzQueueItem> _queue = [];
  int _index = -1;
  int _nextItemId = 1;
  bool _shuffle = false;
  QobuzRepeatMode _repeat = QobuzRepeatMode.off;

  /// いま鳴らしている曲を送った時刻。[_startGrace] の起点。
  DateTime? _startedAt;

  /// **WiiM 本体に預けてある「次の 1 曲」**（issue #8）。預けていなければ null。
  ///
  /// 曲の終わりを見て次を送る方式（§5.3 方式 A）は、見ている人——つまり
  /// ポーリング——が要る。前面から外れるとポーリングは止まるので、別のアプリを
  /// 開いた瞬間にキューがそこで止まっていた。`SetNextAVTransportURI` で先に
  /// 渡しておけば、**アプリが眠っていても本体が自力で次へ移る。**
  QobuzQueueItem? _armed;

  /// 送った URL が実際に鳴ったか。**まだなら載せ方を切り替えて試す**（§5.2）。
  bool _encodingConfirmed = false;

  /// UPnP に落ちたことをもう伝えたか。**曲ごとには言わない**（§5.5）。
  bool _upnpFellBack = false;

  QobuzTab _tab = QobuzTab.queue;

  /// スマホのボトムシートが開いているか（music 側と同じ作法）。
  bool _sheetOpen = false;
  String _query = '';
  QobuzSearchResults _results = const QobuzSearchResults();
  bool _searchBusy = false;

  List<QobuzPlaylist> _playlists = const [];
  QobuzFavorites _favorites = const QobuzFavorites();
  QobuzListing? _listing;
  bool _libraryBusy = false;

  /// シークバーだけを描き直す口。
  ///
  /// ポーリングのたびに [notifyListeners] を叩くと画面全部が毎秒作り直しに
  /// なるので、進捗の購読者だけ分ける（Spotify / MA 側と同じ）。
  @override
  final ChangeNotifier progressTick = ChangeNotifier();

  // ── 参照 ────────────────────────────────────────────────────────────

  QobuzStatus get status => _status;
  String? get errorBanner => _error;
  String? get toast => _toast;
  bool get busy => _busy;

  bool get needsSetup =>
      _status == QobuzStatus.needsSetup ||
      _status == QobuzStatus.authFailed ||
      _status == QobuzStatus.keyFailed;

  bool get isSignedIn => _account != null;
  QobuzAccount? get account => _account;
  QobuzAppConfig? get appConfig => _app;
  WiimConnection? get wiimConnection => _wiimConnection;
  WiimDevice? get device => _device;

  String get deviceName => _device?.name ?? _wiimConnection?.host ?? 'WiiM';

  /// LAN の探索で見つかった WiiM（`WiimDiscovery`）。
  List<WiimCandidate> get candidates => _candidates;
  bool get scanning => _scanning;

  /// 「254 台中 120 台まで見た」。0〜1。**総数 0 のときは 0。**
  double get scanProgress =>
      _scanTotal == 0 ? 0 : (_scanDone / _scanTotal).clamp(0.0, 1.0);

  QobuzTab get tab => _tab;
  bool get sheetOpen => _sheetOpen;

  /// シートを閉じているときに 1 行だけ見せる曲。
  QobuzTrack? get nextTrack => upNext.isEmpty ? null : upNext.first.track;

  void toggleSheet() {
    _sheetOpen = !_sheetOpen;
    notifyListeners();
  }
  String get query => _query;
  QobuzSearchResults get results => _results;
  bool get searchBusy => _searchBusy;

  List<QobuzPlaylist> get playlists => _playlists;
  QobuzFavorites get favorites => _favorites;
  QobuzListing? get listing => _listing;
  bool get libraryBusy => _libraryBusy;

  List<QobuzQueueItem> get queue => List.unmodifiable(_queue);
  int get currentIndex => _index;

  QobuzQueueItem? get currentItem =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  QobuzTrack? get currentTrack => currentItem?.track;

  /// キューの「これから」。いま鳴っている曲より後ろだけ。
  List<QobuzQueueItem> get upNext =>
      _index + 1 >= _queue.length ? const [] : _queue.sublist(_index + 1);

  bool get shuffleEnabled => _shuffle;
  QobuzRepeatMode get repeatMode => _repeat;

  @override
  ArtworkPalette get palette => _paletteResolver.palette;

  @override
  bool get isPlaying => _wiimStatus?.isPlaying ?? false;

  /// 鳴らすものが無い。**時間の表示を 0 に伏せるのに使う。**
  @override
  bool get isStopped => currentTrack == null;

  /// WiiM に届いていて、かつ鳴らすものがあるときだけ押させる。
  /// **両方要る**——繋がっていても空のキューでは送る先が無い。
  @override
  bool get controlsEnabled =>
      _status == QobuzStatus.connected && currentItem != null;
  int get volume => _wiimStatus?.volume ?? 0;
  bool get muted => _wiimStatus?.muted ?? false;

  @override
  Duration get position =>
      _wiimStatus?.correctedPosition(DateTime.now()) ?? Duration.zero;

  /// 曲の長さ。
  ///
  /// **WiiM の `totlen` を鵜呑みにしない。** FLAC のストリームでは 0 で
  /// 返ることがあるので、そのときは Qobuz 側のメタデータで補う。
  @override
  Duration get duration {
    final reported = _wiimStatus?.duration ?? Duration.zero;
    if (reported > Duration.zero) return reported;
    return currentTrack?.duration ?? Duration.zero;
  }

  @override
  double get progressFraction {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// Drawer に添える一行。
  String? get drawerSubtitle => switch (_status) {
    QobuzStatus.needsSetup => '未設定',
    QobuzStatus.authFailed => 'Qobuz のログインが切れました',
    QobuzStatus.keyFailed => 'app_id / app_secret が失効',
    QobuzStatus.connecting => '接続中…',
    QobuzStatus.offline => 'WiiM がオフライン',
    QobuzStatus.connected => currentTrack?.displayTitle ?? '停止中',
  };

  // ── 出入り ──────────────────────────────────────────────────────────

  /// 起動時に一度だけ。保存済みの設定で繋ぎに行く。
  Future<void> start() async {
    _app = await _credentials.loadApp();
    _account = await _credentials.loadAccount();
    _wiimConnection = await _wiimCredentials.load();
    _api.config = _app;
    _api.token = _account?.token;
    _wiim.connection = _wiimConnection;
    if (_app == null ||
        !_app!.isComplete ||
        _account == null ||
        _wiimConnection == null) {
      _set(QobuzStatus.needsSetup);
      return;
    }
    await _connect();
  }

  /// 前面／背面が入れ替わった。
  ///
  /// **背面でも見張り続ける**（issue #8）。別のアプリを開いた瞬間にキューが
  /// 止まっていたのは、ここでポーリングを畳んでいたから——ではなく、iOS が
  /// アプリごと suspend していたから。鳴っている間だけ [PlaybackKeepAlive] で
  /// 生き延びて、間隔を [pollWhileBackground] まで落として見張る。
  ///
  /// 仮に suspend されても、次の 1 曲は本体に預けてある（[_armed]）ので
  /// そこまでは繋がる。前面に戻れば [_absorbAutoAdvance] が辻褄を合わせる。
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      unawaited(_keepAlive.stop());
      if (_status != QobuzStatus.needsSetup) _connect();
    } else {
      // **止まっているのに音声セッションを掴まない。** 他のアプリに対しても
      // 失礼だし、鳴っていないなら進める先も無い。
      if (isPlaying) unawaited(_keepAlive.start());
      _schedulePoll();
    }
  }

  Future<void> retry() async {
    _backoff = _retryMin;
    if (_status == QobuzStatus.needsSetup) return start();
    return _connect();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void dismissToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    if (_toast == null) return;
    _toast = null;
    notifyListeners();
  }

  /// トーストを出す。**必ずここを通す。**
  ///
  /// `_toast` を直接入れると誰も消さないので、画面の下に文言が貼り付いたまま
  /// 残る（「プレイリスト名をキューに追加」が消えない、の正体）。
  void _showToast(String text) {
    _toast = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(_toastDuration, () {
      if (_disposed) return;
      _toast = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // ── 設定 ────────────────────────────────────────────────────────────

  /// WiiM の IP を保存して繋ぎ直す。
  Future<void> saveWiim(String host) async {
    final parsed = WiimConnection.parseHost(host);
    if (parsed == null) {
      _fail('IP アドレスを入力してください');
      return;
    }
    final connection = WiimConnection(host: parsed);
    await _wiimCredentials.save(connection);
    _wiimConnection = connection;
    _wiim.connection = connection;
    // 個体が変われば通る載せ方も変わりうるので、覚えた結果は捨てる。
    _encodingConfirmed = false;
    _wiim.urlEncoding = WiimUrlEncoding.raw;
    await _connect();
  }

  /// 同じ LAN の WiiM を探す（§5.1）。
  ///
  /// **見つかっても勝手には繋がない。** 1 台だけでも「これで合っているか」は
  /// 人にしか分からない（隣家の WiiM が見えることもある）ので、
  /// 選ぶのは [selectWiim]。
  Future<void> discoverWiim() async {
    if (_scanning) return;
    _scanning = true;
    _candidates = const [];
    _scanDone = 0;
    _scanTotal = 0;
    _error = null;
    notifyListeners();
    try {
      await _discovery.scan(
        onFound: (candidate) {
          if (_disposed) return;
          // 見つかるそばから出す。**全部終わるまで待たせない。**
          _candidates = [..._candidates, candidate];
          notifyListeners();
        },
        onProgress: (done, total) {
          if (_disposed) return;
          _scanDone = done;
          _scanTotal = total;
          // 進捗だけの通知。1 台ごとに画面を作り直すのは重いので、
          // 10 台ごとに間引く。
          if (done % 10 == 0 || done == total) notifyListeners();
        },
      );
      if (_disposed) return;
      if (_candidates.isEmpty) {
        _error = _scanTotal == 0
            ? 'この端末の LAN が分かりませんでした。IP を手で入れてください'
            : 'WiiM が見つかりませんでした。'
                  '同じ Wi-Fi にいるか、ローカルネットワークの許可を確認してください';
      }
    } catch (e) {
      debugPrint('WiimDiscovery failed: $e');
      if (!_disposed) _error = 'LAN の探索に失敗しました。IP を手で入れてください';
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  void cancelDiscovery() {
    if (!_scanning) return;
    _discovery.cancel();
    _scanning = false;
    notifyListeners();
  }

  /// 一覧から 1 台選ぶ。
  Future<void> selectWiim(WiimCandidate candidate) => saveWiim(candidate.host);

  /// app_id / app_secret を手で入れる。**bundle.js から取れないときの逃げ道。**
  Future<void> saveAppConfig(String appId, String appSecret) async {
    final config = QobuzAppConfig(
      appId: appId.trim(),
      appSecret: appSecret.trim(),
    );
    await _credentials.saveApp(config);
    _app = config;
    _api.config = config;
    _error = null;
    notifyListeners();
  }

  /// bundle.js から取り直す（§3.2）。
  ///
  /// **候補は複数返る。** どれが当たりかは `track/getFileUrl` を実際に叩いて
  /// みるまで分からないので、検索で拾った 1 曲で総当りして、通ったものを残す。
  Future<void> refreshKeys() async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final keys = await QobuzBundle.discover();
      final winner = await _pickSecret(keys.appId, keys.secrets);
      await saveAppConfig(keys.appId, winner);
      _showToast('app_id / app_secret を取り直しました');
      if (_account != null && _wiimConnection != null) await _connect();
    } on QobuzException catch (e) {
      _api.config = _app;
      _fail('${e.message}（アプリ内ブラウザからの取り込みも試せます）');
    } catch (e) {
      // **黙って終わらせない。** ここに来るのは想定外の型（JSON の壊れなど）で、
      // 何も出ないと「押しても無反応」にしか見えない。
      debugPrint('QobuzController.refreshKeys failed: $e');
      _api.config = _app;
      _fail('鍵を取り直せませんでした。アプリ内ブラウザからの取り込みを試してください');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// アプリ内ブラウザで拾った鍵とトークンを取り込む（§3.2）。
  ///
  /// **ログイン画面の入力より優先する。** Web プレイヤー自身が使っている
  /// app_id とトークンなので、少なくともその瞬間は必ず通る組み合わせ。
  /// user_id だけは付いてこないので `user/get` で引き直す。
  ///
  /// **ログインを先に確定させる。** 以前は app_secret の総当りを先にやって
  /// いて、候補が 1 本も通らないと有効なトークンごと捨てていた——
  /// 「ブラウザでログインしたのに、まだログインを求められる」の正体がこれ。
  /// 秘密が取れるかどうかは再生できるかの話で、ログイン済みかどうかとは別。
  Future<void> applyWebLogin(QobuzWebLoginResult result) async {
    if (result.appId.isEmpty || result.token.isEmpty) {
      _fail('ブラウザから鍵とトークンを取れませんでした');
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      // 1. まずログイン。署名が要らないので app_secret はまだ無くていい。
      _api.token = result.token;
      _api.config = QobuzAppConfig(
        appId: result.appId,
        appSecret: _app?.appSecret ?? '',
      );
      final user = await _api.currentUser();
      final account = QobuzAccount(
        token: result.token,
        userId: user.id,
        displayName: user.displayName,
        subscription: user.subscription,
      );
      await _credentials.saveAccount(account);
      _account = account;

      // 2. 次に鍵。**ここで転んでも 1. は残す。**
      String? keyError;
      try {
        final secret = await _pickSecret(
          result.appId,
          result.secrets,
          fallback: _app?.appSecret,
        );
        await saveAppConfig(result.appId, secret);
      } on QobuzException catch (e) {
        keyError = e.message;
        // 前の app_id / app_secret は組で意味を持つので、崩さず元に戻す。
        // ただし**まだ何も無いとき**は app_id だけでも残す——検索とブラウズは
        // 署名が要らないので、それだけで動く。
        if (_app == null || _app!.appId.isEmpty) {
          await saveAppConfig(result.appId, '');
        } else {
          _api.config = _app;
        }
      }

      await _connect();
      if (keyError == null) {
        _showToast('Qobuz の鍵とログインを取り込みました');
      } else {
        _showToast('Qobuz にログインしました（app_secret はまだです）');
        _error = '$keyError。ログインは取り込めているので、'
            '「Web から取り直す」か手入力で app_secret だけ入れてください';
      }
    } on QobuzException catch (e) {
      _api.config = _app;
      _api.token = _account?.token;
      _fail(e.message);
    } catch (e) {
      debugPrint('QobuzController.applyWebLogin failed: $e');
      _api.config = _app;
      _api.token = _account?.token;
      _fail('ブラウザから取り込んだ値を反映できませんでした');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// app_secret の候補を総当りして、通ったものを返す。
  ///
  /// **どれが当たりかは叩くまで分からない**（`QobuzBundle` 参照）。
  /// 判定は署名が要る `track/getFileUrl` でしかできないので、検索で拾った
  /// 1 曲を使う。
  Future<String> _pickSecret(
    String appId,
    List<String> secrets, {
    String? fallback,
  }) async {
    if (secrets.isEmpty) {
      if (fallback != null && fallback.isNotEmpty) return fallback;
      throw QobuzAppException('app_secret を取れませんでした');
    }
    final sample = await _sampleTrackId(appId);
    for (final secret in secrets) {
      _api.config = QobuzAppConfig(appId: appId, appSecret: secret);
      try {
        await _api.fileUrl(sample, format: QobuzFormat.cd);
        return secret;
      } on QobuzException {
        // この候補は外れ。次へ。
        continue;
      }
    }
    throw QobuzAppException('app_secret の候補がどれも通りませんでした');
  }

  /// 総当りに使う 1 曲。**署名の要らない検索で拾う**ので、
  /// app_secret が外れていても取れる。
  Future<int> _sampleTrackId(String appId) async {
    _api.config = QobuzAppConfig(appId: appId, appSecret: '');
    final results = await _api.search('the', limit: 1);
    final track = results.tracks.isEmpty ? null : results.tracks.first;
    if (track == null) {
      throw QobuzAppException('確認用の曲を取れませんでした（app_id が無効かも）');
    }
    return track.id;
  }

  /// Qobuz にログインする。
  Future<void> login({required String email, required String password}) async {
    if (_app == null || !_app!.isComplete) {
      _fail('先に app_id / app_secret を設定してください');
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final user = await _api.login(email: email, password: password);
      final account = QobuzAccount(
        token: user.token,
        userId: user.id,
        displayName: user.displayName,
        subscription: user.subscription,
      );
      await _credentials.saveAccount(account);
      _account = account;
      _api.token = account.token;
      await _connect();
    } on QobuzException catch (e) {
      _fail(e.message);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _credentials.clearAccount();
    _account = null;
    _api.token = null;
    _queue.clear();
    _index = -1;
    _armed = null;
    _playlists = const [];
    _favorites = const QobuzFavorites();
    _listing = null;
    _set(QobuzStatus.needsSetup);
  }

  // ── 接続 ────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    if (_disposed) return;
    _poll?.cancel();
    _poll = null;
    if (_app == null || _account == null || _wiimConnection == null) {
      _set(QobuzStatus.needsSetup);
      return;
    }
    _set(QobuzStatus.connecting);
    try {
      // **WiiM を先に見る。** Qobuz が通っても WiiM に届かなければ音は出ない
      // し、ローカルネットワーク権限の取りこぼしはここでしか分からない。
      _device = await _wiim.device();
      _wiimStatus = await _wiim.status();
    } on WiimException catch (e) {
      _error = e.message;
      _set(QobuzStatus.offline);
      _scheduleRetry();
      return;
    }
    try {
      await _api.verifyToken();
    } on QobuzAppException catch (e) {
      _error = e.message;
      _set(QobuzStatus.keyFailed);
      return;
    } on QobuzAuthException catch (e) {
      _error = e.message;
      _set(QobuzStatus.authFailed);
      return;
    } on QobuzException catch (e) {
      _error = e.message;
      _set(QobuzStatus.offline);
      _scheduleRetry();
      return;
    }
    _error = null;
    _backoff = _retryMin;
    _set(QobuzStatus.connected);
    _schedulePoll();
    unawaited(loadLibrary());
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _poll?.cancel();
    _poll = Timer(_backoff, _connect);
    final next = _backoff * 2;
    _backoff = next > _retryMax ? _retryMax : next;
  }

  void _schedulePoll() {
    if (_disposed) return;
    _poll?.cancel();
    _poll = Timer(_pollInterval, _tick);
  }

  /// 次に引き直すまでの間。**背面では落とす**（issue #8）。
  Duration get _pollInterval {
    if (!_foreground) return pollWhileBackground;
    return isPlaying ? pollWhilePlaying : pollWhileIdle;
  }

  Future<void> _tick() async {
    if (_disposed) return;
    try {
      final status = await _wiim.status();
      if (_disposed) return;
      final previous = _wiimStatus;
      _wiimStatus = status;
      if (_status != QobuzStatus.connected) {
        _error = null;
        _set(QobuzStatus.connected);
      }
      // **本体が自力で進んだぶんを先に拾う。** ここで辻褄を合わせておかないと、
      // 直後の [_onStatus] が「知らない曲が鳴っている」状態で終わりを判定する。
      if (!_absorbAutoAdvance(previous, status)) _onStatus(previous, status);
      // 曲名や音量が変わったときだけ全体を作り直す。それ以外は
      // シークバーだけ動かす。
      if (previous?.state != status.state ||
          previous?.volume != status.volume ||
          previous?.muted != status.muted) {
        notifyListeners();
      } else {
        progressTick.notifyListeners();
      }
    } on WiimException catch (e) {
      if (_disposed) return;
      _error = e.message;
      _set(QobuzStatus.offline);
      _scheduleRetry();
      return;
    }
    _schedulePoll();
  }

  /// 預けた曲へ本体が自力で移っていたら、こちらの現在位置を合わせる。
  ///
  /// **手を出さない。** もう鳴っているのだから送り直す必要は無く、送れば頭から
  /// 鳴り直してしまう。やるのは `_index` を進めることと、**さらに次の 1 曲を
  /// 預け直すこと**だけ。前面に戻った瞬間もこの経路を通る（issue #8）。
  ///
  /// 見分けは本体が返す曲名で付ける。DIDL の `dc:title` はこちらが渡した
  /// [QobuzTrack.displayTitle] そのものなので、預けた曲の名前が返り始めたら
  /// 移ったということ。**同じ曲を 2 回続けて積んだときは名前で区別が付かない**
  /// ので、そのときだけ「終端まで行って頭に戻った」動きで見る。
  bool _absorbAutoAdvance(WiimStatus? previous, WiimStatus status) {
    final armed = _armed;
    if (armed == null) return false;
    final title = status.title;
    if (title == null || title != armed.track.displayTitle) return false;
    if (title == currentTrack?.displayTitle && !_wrappedAround(previous, status)) {
      return false;
    }
    final index = _queue.indexWhere((e) => e.id == armed.id);
    if (index < 0) {
      // 預けたあとに行ごと消された。もう追えないので忘れる。
      _armed = null;
      return false;
    }
    _index = index;
    _armed = null;
    // **掴み直しの猶予はもう要らない。** 本体が実際に鳴らしている曲なので、
    // ここから先は普通に終わりを見てよい。
    _startedAt = DateTime.now().subtract(_startGrace);
    _encodingConfirmed = true;
    unawaited(_updatePalette(armed.track.imageUrl));
    notifyListeners();
    _rearm();
    return true;
  }

  /// 曲の終端まで行って頭から鳴り直したか。
  ///
  /// **単なる巻き戻しと区別する。** 人が手でシークしたときも位置は戻るので、
  /// 「終わり際にいた」ことまで揃って初めて曲が変わったと見る。
  bool _wrappedAround(WiimStatus? previous, WiimStatus status) {
    if (previous == null) return false;
    if (status.position >= previous.position) return false;
    final total = previous.duration;
    if (total <= Duration.zero) return false;
    return previous.position >= total - const Duration(seconds: 20);
  }

  /// ポーリング 1 回ぶんの判断。**曲の終わりを見て次を送る。**
  void _onStatus(WiimStatus? previous, WiimStatus status) {
    final started = _startedAt;
    if (started == null || currentItem == null) return;
    final since = DateTime.now().difference(started);

    // 送った URL がまだ鳴っていない。載せ方を切り替えて一度だけ試す（§5.2）。
    if (!_encodingConfirmed) {
      if (status.isPlaying) {
        _encodingConfirmed = true;
      } else if (since > const Duration(seconds: 3) &&
          _wiim.urlEncoding == WiimUrlEncoding.raw) {
        _wiim.urlEncoding = WiimUrlEncoding.percent;
        debugPrint('WiiM: URL を percent-encode で送り直します');
        unawaited(_playCurrent(retry: true));
        return;
      }
    }

    if (since < _startGrace) return;
    if (!status.state.isIdle) return;
    // 掴み損ねではなく本当に終わったのか。**位置が進んでいたかで見る。**
    // 曲頭で止まったなら次へ送っても同じことになるので、キューを止める。
    final played = previous?.position ?? status.position;
    if (played <= Duration.zero) {
      _startedAt = null;
      _fail('WiiM が曲を鳴らせませんでした');
      return;
    }
    unawaited(_advance());
  }

  // ── 再生 ────────────────────────────────────────────────────────────

  @override
  Future<void> togglePlayPause() async {
    if (currentItem == null) return;
    try {
      if (isPlaying) {
        await _wiim.pause();
      } else if (_wiimStatus?.state == WiimState.pause) {
        await _wiim.resume();
      } else {
        // 停止から押されたら、いまの曲を頭から送り直す。
        await _playCurrent();
        return;
      }
      await _refreshSoon();
    } on WiimException catch (e) {
      _fail(e.message);
    }
  }

  @override
  Future<void> skipNext() => _advance(manual: true);

  @override
  Future<void> skipPrevious() async {
    // 曲頭でなければ頭出し。壁掛けで押し間違えたときに前の曲へ飛ばない。
    if (position > const Duration(seconds: 3)) {
      await _playCurrent();
      return;
    }
    if (_index <= 0) {
      await _playCurrent();
      return;
    }
    _index -= 1;
    notifyListeners();
    await _playCurrent();
  }

  Future<void> seek(Duration position) async {
    try {
      await _wiim.seek(position);
      await _refreshSoon();
    } on WiimException catch (e) {
      _fail(e.message);
    }
  }

  Future<void> setVolume(int level) async {
    try {
      await _wiim.setVolume(level);
      await _refreshSoon();
    } on WiimException catch (e) {
      _fail(e.message);
    }
  }

  Future<void> toggleMute() async {
    try {
      await _wiim.setMute(!muted);
      await _refreshSoon();
    } on WiimException catch (e) {
      _fail(e.message);
    }
  }

  void setShuffle(bool value) {
    if (_shuffle == value) return;
    _shuffle = value;
    if (value) _shuffleUpNext();
    notifyListeners();
    _rearm();
  }

  void cycleRepeat() {
    _repeat = _repeat.next;
    notifyListeners();
    // 繰り返しが変われば「次に鳴るはずの曲」も変わる。預け直す。
    _rearm();
  }

  /// これから鳴る分だけ混ぜる。**鳴っている曲は動かさない。**
  ///
  /// ただし [includeCurrent] なら 1 曲目も混ぜる。積み直してこれから鳴らす
  /// ところなら「鳴っている曲」はまだ無く、先頭を守ると**必ずプレイリストの
  /// 1 曲目から始まる**——シャッフルに見えない。
  void _shuffleUpNext({bool includeCurrent = false}) {
    final head = includeCurrent ? max(_index, 0) : _index + 1;
    if (head >= _queue.length) return;
    final rest = _queue.sublist(head)..shuffle(Random());
    _queue.replaceRange(head, _queue.length, rest);
  }

  /// キューの行をタップして鳴らす。
  Future<void> playItem(QobuzQueueItem item) async {
    final index = _queue.indexWhere((e) => e.id == item.id);
    if (index < 0) return;
    _index = index;
    notifyListeners();
    await _playCurrent();
  }

  void removeItem(QobuzQueueItem item) {
    final index = _queue.indexWhere((e) => e.id == item.id);
    if (index < 0) return;
    _queue.removeAt(index);
    // 鳴っている曲より前を消したら、現在位置も 1 つ手前にずれる。
    if (index < _index) _index -= 1;
    notifyListeners();
    _rearm();
  }

  /// 並べ替え（`ReorderableListView` から）。
  void moveItem(int from, int to) {
    final head = _index + 1;
    final source = head + from;
    var target = head + to;
    if (source < 0 || source >= _queue.length) return;
    if (target > _queue.length) target = _queue.length;
    final item = _queue.removeAt(source);
    _queue.insert(source < target ? target - 1 : target, item);
    notifyListeners();
    _rearm();
  }

  void clearQueue() {
    // 鳴っている曲は残す。止めたいなら停止ボタンで。
    final current = currentItem;
    _queue
      ..clear()
      ..addAll([?current]);
    _index = current == null ? -1 : 0;
    notifyListeners();
    _rearm();
  }

  // ── キューに積む ────────────────────────────────────────────────────

  Future<void> enqueueTrack(
    QobuzTrack track, {
    QobuzQueueOption option = QobuzQueueOption.add,
  }) => enqueueTracks([track], option: option, label: track.displayTitle);

  Future<void> enqueueAlbum(
    QobuzAlbum album, {
    QobuzQueueOption option = QobuzQueueOption.add,
    bool? shuffle,
  }) async {
    var tracks = album.tracks;
    if (tracks.isEmpty) {
      final full = await _guard(() => _api.album(album.id));
      if (full == null) return;
      tracks = full.tracks;
    }
    await enqueueTracks(
      tracks,
      option: option,
      label: album.title,
      shuffle: shuffle,
    );
  }

  Future<void> enqueuePlaylist(
    QobuzPlaylist playlist, {
    QobuzQueueOption option = QobuzQueueOption.add,
    bool? shuffle,
  }) async {
    var tracks = playlist.tracks;
    if (tracks.isEmpty) {
      final full = await _guard(
        () => _api.playlist(playlist.id, ownerUserId: _account?.userId),
      );
      if (full == null) return;
      tracks = full.tracks;
    }
    await enqueueTracks(
      tracks,
      option: option,
      label: playlist.name,
      shuffle: shuffle,
    );
  }

  /// ライブラリで選んだ 1 件をキューごと差し替えて流す。
  ///
  /// **music の `PlayerController.playPlaylist` と同じ役。** あちらと同じく、
  /// いまのキューが消える操作なので、呼ぶ前に画面側で確認を取ること
  /// （`QueuePlayConfirm`）。シャッフルもあちらと同じくここで確定させる。
  Future<void> playPlaylist(QobuzPlaylist playlist, {bool shuffle = false}) =>
      enqueuePlaylist(
        playlist,
        option: QobuzQueueOption.play,
        shuffle: shuffle,
      );

  Future<void> playAlbum(QobuzAlbum album, {bool shuffle = false}) =>
      enqueueAlbum(album, option: QobuzQueueOption.play, shuffle: shuffle);

  /// キューに積む本体。
  ///
  /// **鳴らせない曲は落とす。** `streamable` が false のものを積んでおくと、
  /// そこでキューが止まって「なぜか次に進まない」になる。
  Future<void> enqueueTracks(
    List<QobuzTrack> tracks, {
    QobuzQueueOption option = QobuzQueueOption.add,
    String? label,
    bool? shuffle,
  }) async {
    final playable = tracks.where((t) => t.streamable).toList();
    if (playable.isEmpty) {
      _fail('鳴らせる曲がありませんでした');
      return;
    }
    final items = [
      for (final track in playable)
        QobuzQueueItem(id: _nextItemId++, track: track),
    ];
    final name = label ?? items.first.track.displayTitle;
    switch (option) {
      case QobuzQueueOption.replace || QobuzQueueOption.play:
        _queue
          ..clear()
          ..addAll(items);
        _index = 0;
      case QobuzQueueOption.next:
        _queue.insertAll(_index + 1, items);
      case QobuzQueueOption.add:
        _queue.addAll(items);
        // 何も鳴っていなければ、積んだ先頭から始める。
        if (_index < 0) _index = 0;
    }
    // **積み終わってから混ぜる。** `setShuffle` は「もう on」のときに素通り
    // するので、差し替えた並びが混ざらないまま鳴り出してしまう。
    if (shuffle != null) {
      _shuffle = shuffle;
      if (shuffle) {
        // 積み直してこれから鳴らす分は、1 曲目も込みで混ぜる。
        final fresh =
            option == QobuzQueueOption.play ||
            option == QobuzQueueOption.replace;
        _shuffleUpNext(includeCurrent: fresh);
      }
    }
    var message = switch (option) {
      QobuzQueueOption.play || QobuzQueueOption.replace => '$name を再生',
      QobuzQueueOption.next => '$name を次に',
      QobuzQueueOption.add => '$name をキューに追加',
    };
    final dropped = tracks.length - playable.length;
    if (dropped > 0) message = '$message（鳴らせない $dropped 曲は除外）';
    _showToast(message);
    final shouldStart =
        option == QobuzQueueOption.play ||
        option == QobuzQueueOption.replace ||
        (!isPlaying && _startedAt == null);
    if (shouldStart) {
      await _playCurrent();
    } else {
      // 鳴っているものはそのまま。**ただし「次」は変わったかもしれない**
      // ので預け直す（末尾に足しただけでも、キューが 1 曲だけだったなら
      // それが次になる）。
      _rearm();
    }
  }

  /// 次の曲へ。[manual] なら曲送りボタン、そうでなければ曲が終わった。
  Future<void> _advance({bool manual = false}) async {
    if (_queue.isEmpty) return;
    if (!manual && _repeat == QobuzRepeatMode.one) {
      await _playCurrent();
      return;
    }
    if (_index + 1 < _queue.length) {
      _index += 1;
    } else if (_repeat == QobuzRepeatMode.all) {
      _index = 0;
    } else {
      // 終わり。**キューは残す**——同じ並びをもう一度鳴らしたいことが多い。
      _startedAt = null;
      notifyListeners();
      // 預けたものが残っていれば消す。ここは止まるところ。
      _rearm();
      // **鳴らすものが尽きたら降りる。** 背面で生き延び続ける理由が無い。
      unawaited(_keepAlive.stop());
      return;
    }
    notifyListeners();
    await _playCurrent();
  }

  /// いまの曲を WiiM に送る。
  ///
  /// **署名付き URL はここで取る**（§3.4）。キューに積んだ時点で取ると、
  /// 24 時間後に後半が失効した URL の列になる。
  Future<void> _playCurrent({bool retry = false}) async {
    final item = currentItem;
    if (item == null) return;
    // これから現在の URI を差し替える。**預けてあるものは一旦忘れる**——
    // 本体側に残っていても、この後の [_armNext] が上書きするか消しに行く。
    _armed = null;
    // 背景の色は「いま鳴らすもの」から。**送るのと同じ入口で拾う**ので、
    // どの経路（タップ・曲送り・キュー入れ替え）から来ても取りこぼさない。
    unawaited(_updatePalette(item.track.imageUrl));
    if (_wiimConnection == null) {
      _fail('WiiM の IP が設定されていません');
      return;
    }
    try {
      final file = await _api.fileUrl(
        item.track.id,
        // ハイレゾを頼んで、駄目なら Qobuz 側が落として返す。
        format: QobuzFormat.hires192,
      );
      if (_disposed || currentItem?.id != item.id) return;
      // **見出しは WiiM 本体のディスプレイのために渡す**（§5.5）。
      // これが無いと Ultra の画面には署名付き URL がそのまま出る。
      final route = await _wiim.play(
        file.url,
        meta: WiimTrackMetadata(
          title: item.track.displayTitle,
          artist: item.track.artist,
          album: item.track.albumTitle,
          artUrl: item.track.imageUrl,
          duration: item.track.duration,
          mimeType: file.mimeType,
        ),
      );
      _startedAt = DateTime.now();
      // UPnP で通ったなら載せ方を試し直す必要が無い（§5.2 は HTTP API の話）。
      if (route == WiimPlayRoute.upnp) {
        _encodingConfirmed = true;
        _upnpFellBack = false;
      } else if (!retry) {
        _encodingConfirmed = false;
      }
      // **落ちたことを 1 度だけ言う。** 黙って HTTP API に倒れると、鳴っては
      // いるのに本体の画面だけ署名付き URL と既定のジャケットに戻り、
      // アプリ側からは何も分からない。曲ごとに出すとうるさいので、
      // 通っていた状態から落ちた回だけ。
      if (route == WiimPlayRoute.httpApi && !_upnpFellBack) {
        _upnpFellBack = true;
        _showToast('WiiM の UPnP に届かず、本体の画面は曲名なしになります');
      }
      _error = null;
      notifyListeners();
      await _refreshSoon();
      // **鳴らし始めたらすぐ次を預ける。** 前面から外れるのは曲の途中とは
      // 限らないので、終わり際まで待たない（issue #8）。
      _rearm();
    } on QobuzAppException catch (e) {
      _error = e.message;
      _set(QobuzStatus.keyFailed);
    } on QobuzAuthException catch (e) {
      _error = e.message;
      _set(QobuzStatus.authFailed);
    } on QobuzException catch (e) {
      // 1 曲鳴らせないだけでキューを止めない。次へ送る。
      // **バナーではなくトーストに出す。** 次の曲が鳴り出した時点で
      // バナーは消えてしまい、何が起きたのか分からなくなる。
      _showToast('${item.track.displayTitle}: ${e.message}');
      if (_index + 1 < _queue.length) {
        _index += 1;
        await _playCurrent();
      }
    } on WiimException catch (e) {
      _error = e.message;
      _set(QobuzStatus.offline);
      _scheduleRetry();
    }
  }

  /// いまの曲の次に鳴るはずの行。**キューの並びと繰り返しの設定で決まる。**
  QobuzQueueItem? get _followingItem {
    if (_queue.isEmpty || _index < 0) return null;
    // one は「同じ曲をもう一度」。本体に預けるのも同じ曲でよい。
    if (_repeat == QobuzRepeatMode.one) return currentItem;
    if (_index + 1 < _queue.length) return _queue[_index + 1];
    if (_repeat == QobuzRepeatMode.all) return _queue.first;
    return null;
  }

  /// 次の 1 曲を預け直す。**待たない。**
  ///
  /// キューをいじるたびに呼ぶ（並べ替え・削除・割り込み・繰り返しの切り替え）。
  /// 署名付き URL を 1 本取りに行くので、画面の操作をこれで止めない。
  void _rearm() => unawaited(_armNext());

  /// 次の 1 曲を WiiM 本体に預ける（issue #8）。
  ///
  /// **失敗は黙って飲む。** 預けられなくても「前面にいる間は今までどおり
  /// 曲送りできる」に戻るだけで、画面に出すほどの異常ではない。
  Future<void> _armNext() async {
    if (_disposed || _wiimConnection == null) return;
    final target = _followingItem;
    if (target == null) {
      // 最後まで来た。**残っている予約を必ず消す**——消さないと、止まるはずの
      // ところで前に預けた曲がもう 1 曲鳴る。
      //
      // **「預けた覚えが無いから省く」はしない。** `SetAVTransportURI` が
      // 予約まで消すかは機種任せで、こちらからは分からない。空振りの SOAP が
      // 1 回増えるほうが、余計な 1 曲が鳴るより安い。
      _armed = null;
      try {
        await _wiim.clearNext();
      } on WiimException catch (e) {
        debugPrint('QobuzController: 予約を消せませんでした（$e）');
      }
      return;
    }
    // 預け直す前に手放す。途中で転んだときに「預けてある」と誤解しない。
    _armed = null;
    try {
      final file = await _api.fileUrl(
        target.track.id,
        format: QobuzFormat.hires192,
      );
      // 取っている間にキューが動いていたら捨てる。
      if (_disposed || _followingItem?.id != target.id) return;
      final ok = await _wiim.preloadNext(
        file.url,
        WiimTrackMetadata(
          title: target.track.displayTitle,
          artist: target.track.artist,
          album: target.track.albumTitle,
          artUrl: target.track.imageUrl,
          duration: target.track.duration,
          mimeType: file.mimeType,
        ),
      );
      if (_disposed || _followingItem?.id != target.id) return;
      _armed = ok ? target : null;
    } on QobuzException catch (e) {
      // 鳴らせない曲かもしれない。**ここでは何もしない**——実際に順番が回って
      // きたときに [_playCurrent] が同じ失敗を拾って読み飛ばす。
      debugPrint('QobuzController: 次の曲を用意できませんでした（$e）');
    } on WiimException catch (e) {
      debugPrint('QobuzController: 次の曲を預けられませんでした（$e）');
    }
  }

  /// 操作した直後は間を置かずに 1 回だけ引き直す。押した手応えのため。
  Future<void> _refreshSoon() async {
    _poll?.cancel();
    _poll = Timer(const Duration(milliseconds: 400), _tick);
  }

  // ── 検索 ────────────────────────────────────────────────────────────

  void onQueryChanged(String value) {
    _query = value;
    _searchTimer?.cancel();
    final text = value.trim();
    if (text.isEmpty) {
      _results = const QobuzSearchResults();
      _searchBusy = false;
      notifyListeners();
      return;
    }
    _searchBusy = true;
    notifyListeners();
    _searchTimer = Timer(_searchDebounce, () => _runSearch(text));
  }

  Future<void> _runSearch(String text) async {
    try {
      final results = await _api.search(text);
      // 打ち直されていたら捨てる。
      if (_disposed || _query.trim() != text) return;
      _results = results;
      _searchBusy = false;
      notifyListeners();
    } on QobuzException catch (e) {
      if (_disposed || _query.trim() != text) return;
      _searchBusy = false;
      _handle(e);
    }
  }

  void selectTab(QobuzTab value) {
    if (_tab == value) return;
    _tab = value;
    // キュー以外を選んだらシートを開ける。**閉じたまま切り替えても
    // 1 行プレビューしか見えず、選んだ意味が無い**（music 側と同じ）。
    if (value != QobuzTab.queue) _sheetOpen = true;
    notifyListeners();
  }

  // ── ライブラリ ──────────────────────────────────────────────────────

  Future<void> loadLibrary() async {
    if (_account == null) return;
    _libraryBusy = true;
    notifyListeners();
    final playlists = await _guard(
      () => _api.userPlaylists(ownerUserId: _account?.userId),
    );
    final favorites = await _guard(() => _api.favorites());
    if (_disposed) return;
    if (playlists != null) _playlists = playlists;
    if (favorites != null) _favorites = favorites;
    _libraryBusy = false;
    notifyListeners();
  }

  Future<void> openPlaylist(QobuzPlaylist playlist) async {
    _libraryBusy = true;
    notifyListeners();
    final full = await _guard(
      () => _api.playlist(playlist.id, ownerUserId: _account?.userId),
    );
    if (_disposed) return;
    _libraryBusy = false;
    if (full != null) {
      _listing = QobuzListing(
        title: full.name,
        subtitle: '${full.tracks.length} 曲',
        imageUrl: full.imageUrl,
        tracks: full.tracks,
      );
    }
    notifyListeners();
  }

  Future<void> openAlbum(QobuzAlbum album) async {
    _libraryBusy = true;
    notifyListeners();
    final full = await _guard(() => _api.album(album.id));
    if (_disposed) return;
    _libraryBusy = false;
    if (full != null) {
      _listing = QobuzListing(
        title: full.title,
        subtitle: full.artist,
        imageUrl: full.imageUrl,
        tracks: full.tracks,
      );
    }
    notifyListeners();
  }

  void closeListing() {
    if (_listing == null) return;
    _listing = null;
    notifyListeners();
  }

  // ── 下回り ──────────────────────────────────────────────────────────

  /// Qobuz 呼び出しの共通の受け。認証と鍵の失効だけ状態に反映する。
  Future<T?> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on QobuzException catch (e) {
      _handle(e);
      return null;
    }
  }

  void _handle(QobuzException e) {
    if (e is QobuzAppException) {
      _error = e.message;
      _set(QobuzStatus.keyFailed);
      return;
    }
    if (e is QobuzAuthException) {
      _error = e.message;
      _set(QobuzStatus.authFailed);
      return;
    }
    _fail(e.message);
  }

  Future<void> _updatePalette(String? url) async {
    final changed = await _paletteResolver.resolve(url);
    if (changed && !_disposed) notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  void _set(QobuzStatus status) {
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
    unawaited(_keepAlive.stop());
    _poll?.cancel();
    _searchTimer?.cancel();
    _toastTimer?.cancel();
    _api.close();
    _wiim.close();
    _discovery.close();
    progressTick.dispose();
    super.dispose();
  }
}
