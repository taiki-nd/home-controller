import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/qobuz_models.dart';
import 'package:spotify_remote/models/wiim_models.dart';
import 'package:spotify_remote/services/qobuz_api.dart';
import 'package:spotify_remote/services/qobuz_credentials.dart';
import 'package:spotify_remote/services/wiim_api.dart';
import 'package:spotify_remote/services/wiim_credentials.dart';
import 'package:spotify_remote/services/wiim_upnp.dart';
import 'package:spotify_remote/state/qobuz_controller.dart';

/// hi-res 側のテスト用の偽物一式。
///
/// **Keychain も HTTP も触らない。** `QobuzCredentials` / `WiimCredentials` は
/// 生成しただけでは端末に触らない作りなので、読み書きのメソッドだけ差し替える。

const testAppConfig = QobuzAppConfig(
  appId: '123456789',
  appSecret: 'abcdef0123456789abcdef0123456789',
);

const testAccount = QobuzAccount(
  token: 'token-xxx',
  userId: 42,
  displayName: 'わたし',
);

const testWiim = WiimConnection(host: '192.168.1.42');

class FakeQobuzCredentials extends QobuzCredentials {
  FakeQobuzCredentials({this.app = testAppConfig, this.account = testAccount});

  QobuzAppConfig? app;
  QobuzAccount? account;

  @override
  Future<QobuzAppConfig?> loadApp() async => app;

  @override
  Future<void> saveApp(QobuzAppConfig config) async => app = config;

  @override
  Future<QobuzAccount?> loadAccount() async => account;

  @override
  Future<void> saveAccount(QobuzAccount value) async => account = value;

  @override
  Future<void> clearAccount() async => account = null;

  @override
  Future<void> clearAll() async {
    app = null;
    account = null;
  }
}

class FakeWiimCredentials extends WiimCredentials {
  FakeWiimCredentials([this.saved = testWiim]);

  WiimConnection? saved;

  @override
  Future<WiimConnection?> load() async => saved;

  @override
  Future<void> save(WiimConnection connection) async => saved = connection;

  @override
  Future<void> clear() async => saved = null;
}

class FakeQobuzApi extends QobuzApi {
  FakeQobuzApi() : super(config: testAppConfig);

  /// `fileUrl` を呼ばれた track_id を呼ばれた順に。
  /// **再生直前に取っているか**の確認に使う。
  final fileUrlCalls = <int>[];

  QobuzSearchResults searchResults = const QobuzSearchResults();
  List<QobuzPlaylist> playlists = const [];
  QobuzFavorites favoritesResult = const QobuzFavorites();

  /// これを立てると `fileUrl` が転ぶ（鳴らせない曲の再現）。
  final failingTrackIds = <int>{};

  /// これを入れると、**この app_secret のときだけ** `fileUrl` が通る。
  /// bundle.js の候補を総当りする経路（`_pickSecret`）の再現用。
  String? winningSecret;

  /// `currentUser` が返す人。
  QobuzUser user = const QobuzUser(
    id: 42,
    token: 'token-xxx',
    displayName: 'わたし',
    subscription: 'Studio',
  );

  @override
  Future<void> verifyToken() async {}

  @override
  Future<QobuzUser> currentUser() async => user;

  @override
  Future<QobuzSearchResults> search(String query, {int limit = 30}) async =>
      searchResults;

  @override
  Future<List<QobuzPlaylist>> userPlaylists({int? ownerUserId}) async =>
      playlists;

  @override
  Future<QobuzFavorites> favorites({int limit = 100}) async => favoritesResult;

  /// `playlist/get?extra=tracks` が返す中身。**一覧の `tracks` は空**なので、
  /// ライブラリから 1 件選んで流す経路は必ずここを通る。
  List<QobuzTrack> playlistTracks = [track(11), track(12)];

  @override
  Future<QobuzPlaylist> playlist(int playlistId, {int? ownerUserId}) async =>
      QobuzPlaylist(
        id: playlistId,
        name: 'プレイリスト $playlistId',
        tracksCount: playlistTracks.length,
        tracks: playlistTracks,
      );

  @override
  Future<QobuzFileUrl> fileUrl(
    int trackId, {
    QobuzFormat format = QobuzFormat.hires192,
    DateTime? now,
  }) async {
    fileUrlCalls.add(trackId);
    if (failingTrackIds.contains(trackId)) {
      throw QobuzException('この曲は再生できません');
    }
    if (winningSecret != null && config?.appSecret != winningSecret) {
      throw QobuzAppException('invalid signature');
    }
    return QobuzFileUrl(
      trackId: trackId,
      url: 'https://streaming.qobuz.com/file/$trackId.flac?etsp=1&sig=abc',
      formatId: format.id,
      bitDepth: 24,
      samplingRate: 96,
    );
  }

  @override
  void close() {}
}

class FakeWiimApi extends WiimApi {
  FakeWiimApi() : super(connection: testWiim);

  /// 投げた URL を順に。
  final playedUrls = <String>[];

  /// 一緒に渡した見出し（WiiM 本体のディスプレイ用）。
  final playedMeta = <WiimTrackMetadata?>[];
  final commands = <String>[];

  /// UPnP が通らない個体を作る。HTTP API に落ちることを見るのに使う。
  bool upnpAvailable = true;

  WiimStatus current = idleStatus();

  /// WiiM に届かない状態。**接続が落ちたときの画面**を作るのに使う。
  bool failing = false;

  @override
  Future<WiimDevice> device() async {
    if (failing) throw WiimException('WiiM に接続できません');
    return const WiimDevice(name: 'リビング');
  }

  @override
  Future<WiimStatus> status({DateTime? now}) async {
    if (failing) throw WiimException('WiiM に接続できません');
    return current;
  }

  @override
  Future<WiimPlayRoute> play(
    String url, {
    WiimTrackMetadata? meta,
    WiimUrlEncoding? encoding,
    DateTime? now,
  }) async {
    playedMeta.add(meta);
    commands.add('play');
    if (meta != null && upnpAvailable) {
      // UPnP はエスケープを気にしないので URL は素のまま載る。
      playedUrls.add(url);
      return WiimPlayRoute.upnp;
    }
    playedUrls.add((encoding ?? urlEncoding).apply(url));
    return WiimPlayRoute.httpApi;
  }

  @override
  Future<void> pause() async => commands.add('pause');

  @override
  Future<void> resume() async => commands.add('resume');

  @override
  Future<void> stop() async => commands.add('stop');

  @override
  Future<void> seek(Duration position) async =>
      commands.add('seek:${position.inSeconds}');

  @override
  Future<void> setVolume(int level) async => commands.add('vol:$level');

  @override
  Future<void> setMute(bool muted) async => commands.add('mute:$muted');

  @override
  void close() {}
}

WiimStatus idleStatus() => WiimStatus(
  state: WiimState.stop,
  position: Duration.zero,
  duration: Duration.zero,
  volume: 40,
  muted: false,
  receivedAt: DateTime.now(),
);

WiimStatus playingStatus({
  Duration position = const Duration(seconds: 5),
  Duration duration = const Duration(minutes: 4),
}) => WiimStatus(
  state: WiimState.play,
  position: position,
  duration: duration,
  volume: 40,
  muted: false,
  receivedAt: DateTime.now(),
);

QobuzTrack track(
  int id, {
  String? title,
  bool streamable = true,
  bool hires = true,
  String? imageUrl,
  String? largeImageUrl,
}) => QobuzTrack(
  id: id,
  title: title ?? '曲 $id',
  artist: 'アーティスト',
  albumTitle: 'アルバム',
  imageUrl: imageUrl,
  largeImageUrl: largeImageUrl,
  duration: const Duration(minutes: 4),
  streamable: streamable,
  hiresStreamable: hires,
  maxBitDepth: 24,
  maxSamplingRate: 96,
);

/// 繋がった [QobuzController] と偽物を返す。
Future<(QobuzController, FakeQobuzApi, FakeWiimApi)> started() async {
  final api = FakeQobuzApi();
  final wiim = FakeWiimApi();
  final controller = QobuzController(
    credentials: FakeQobuzCredentials(),
    wiimCredentials: FakeWiimCredentials(),
    api: api,
    wiim: wiim,
  );
  await controller.start();
  await pumpEventQueue();
  return (controller, api, wiim);
}
