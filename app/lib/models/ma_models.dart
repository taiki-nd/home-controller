import 'package:flutter/foundation.dart';

/// Music Assistant の JSON から、画面が使う分だけ削って持つ
/// （`docs/music-assistant-integration.md` §4）。
///
/// MA 側のモデルはサーバーの dataclass がそのまま出てくるので項目が多い。
/// 増やすときは「画面のどこに出るか」が言えるものだけにする。

/// 接続直後に頼まなくても飛んでくるサーバー情報。
@immutable
class MaServerInfo {
  const MaServerInfo({
    required this.serverId,
    required this.serverVersion,
    required this.schemaVersion,
    this.name,
  });

  final String serverId;
  final String serverVersion;
  final int schemaVersion;
  final String? name;

  /// 認証が要る世代か（`auth` コマンドは schema 28 / MA 2.8 から）。
  bool get requiresAuth => schemaVersion >= 28;

  /// `imageproxy/<proxy_id>` 形式が使えるか。
  bool get hasImageProxyIds => schemaVersion >= 31;

  static MaServerInfo? tryFrom(Map<String, dynamic> json) {
    final id = json['server_id'];
    final schema = json['schema_version'];
    if (id is! String || schema is! int) return null;
    return MaServerInfo(
      serverId: id,
      serverVersion: json['server_version'] as String? ?? '',
      schemaVersion: schema,
      name: json['name'] as String?,
    );
  }
}

/// 再生状態。MA の `PlaybackState`。
enum MaPlaybackState {
  idle,
  paused,
  playing,
  unknown;

  static MaPlaybackState parse(Object? raw) => switch (raw) {
    'idle' => MaPlaybackState.idle,
    'paused' => MaPlaybackState.paused,
    'playing' => MaPlaybackState.playing,
    _ => MaPlaybackState.unknown,
  };
}

/// リピート。MA の `RepeatMode`。
enum MaRepeatMode {
  off,
  one,
  all;

  static MaRepeatMode parse(Object? raw) => switch (raw) {
    'one' => MaRepeatMode.one,
    'all' => MaRepeatMode.all,
    _ => MaRepeatMode.off,
  };

  String get wire => name;

  /// off → all → one → off。ボタン 1 つで回すため。
  MaRepeatMode get next => switch (this) {
    MaRepeatMode.off => MaRepeatMode.all,
    MaRepeatMode.all => MaRepeatMode.one,
    MaRepeatMode.one => MaRepeatMode.off,
  };
}

/// キューへの積み方。MA の `QueueOption`。
enum MaQueueOption {
  /// いま鳴っているものを止めて、これを鳴らす。
  play,

  /// キューを捨てて入れ替える。
  replace,

  /// 次の 1 曲として割り込ませる。
  next,

  /// 末尾に足す。
  add;

  String get wire => name;
}

/// アートワーク 1 枚。**そのまま URL とは限らない**（§4.1）。
@immutable
class MaImage {
  const MaImage({
    required this.path,
    required this.provider,
    this.remotelyAccessible = false,
    this.proxyId,
  });

  final String path;
  final String provider;
  final bool remotelyAccessible;
  final String? proxyId;

  static MaImage? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    return MaImage(
      path: path,
      provider: raw['provider'] as String? ?? '',
      remotelyAccessible: raw['remotely_accessible'] == true,
      proxyId: raw['proxy_id'] as String?,
    );
  }

  /// 表示に使う URL を組み立てる。
  ///
  /// [size] は必ず渡す。WiiM のファームは長い URL でアルバムアートを落とす
  /// ことがあり、imageproxy の URL は短いほうがよい（§4.1）。
  String url(Uri base, {int size = 512}) {
    if (remotelyAccessible) return path;
    if (proxyId != null) {
      return base.replace(path: '/imageproxy/$proxyId', queryParameters: {
        'size': '$size',
      }).toString();
    }
    // 旧形式。path は二重エンコードして渡す決まり。
    return base.replace(path: '/imageproxy', queryParameters: {
      'path': Uri.encodeComponent(path),
      'provider': provider,
      'size': '$size',
    }).toString();
  }
}

/// 出力先。MA の `Player`。
@immutable
class MaPlayer {
  const MaPlayer({
    required this.playerId,
    required this.name,
    required this.available,
    required this.provider,
    this.powered,
    this.volumeLevel,
    this.playbackState = MaPlaybackState.idle,
    this.hideInUi = false,
    this.syncedTo,
    this.activeGroup,
  });

  final String playerId;
  final String name;
  final bool available;

  /// プロバイダの instance_id。`wiim` で始まるものが WiiM。
  final String provider;

  /// 電源を持たないプレイヤーもある（null）。
  final bool? powered;
  final int? volumeLevel;
  final MaPlaybackState playbackState;
  final bool hideInUi;

  /// 他のプレイヤーに同期でぶら下がっている場合の親。
  final String? syncedTo;

  /// グループの一員として鳴っている場合の親。
  final String? activeGroup;

  /// 一覧に出すか。使えないもの・隠す指定のもの・従属しているものは出さない
  /// （操作しても親のキューに吸われるので、選ばせると混乱する）。
  bool get isSelectable =>
      available && !hideInUi && syncedTo == null && activeGroup == null;

  /// このプレイヤーのキュー。MA では両者の id が一致する。
  String get queueId => playerId;

  static MaPlayer fromJson(Map<String, dynamic> json) => MaPlayer(
    playerId: json['player_id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    available: json['available'] != false,
    provider: json['provider'] as String? ?? '',
    powered: json['powered'] as bool?,
    volumeLevel: (json['volume_level'] as num?)?.round(),
    playbackState: MaPlaybackState.parse(json['playback_state']),
    hideInUi: json['hide_in_ui'] == true,
    syncedTo: json['synced_to'] as String?,
    activeGroup: json['active_group'] as String?,
  );
}

/// キューの 1 行。MA の `QueueItem`。
@immutable
class MaQueueItem {
  const MaQueueItem({
    required this.queueItemId,
    required this.name,
    this.artist,
    this.duration,
    this.image,
    this.uri,
    this.index = 0,
  });

  final String queueItemId;

  /// MA は `アーティスト - 曲名` の形で入れてくることが多い。
  /// [artist] が取れたときは [title] で曲名だけに割る。
  final String name;
  final String? artist;
  final Duration? duration;
  final MaImage? image;
  final String? uri;
  final int index;

  /// 曲名だけ。`name` の頭に付いているアーティスト名を落とす。
  String get title {
    final artist = this.artist;
    if (artist == null || artist.isEmpty) return name;
    final prefix = '$artist - ';
    return name.startsWith(prefix) ? name.substring(prefix.length) : name;
  }

  /// どのプロバイダの曲か（`qobuz` / `spotify` など）。URI の scheme に出る。
  String? get provider {
    final uri = this.uri;
    if (uri == null) return null;
    final scheme = uri.split('://').first;
    return scheme == uri ? null : scheme;
  }

  static MaQueueItem? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = json['queue_item_id'];
    if (id is! String) return null;
    final media = json['media_item'];
    final seconds = (json['duration'] as num?)?.round();
    return MaQueueItem(
      queueItemId: id,
      name: json['name'] as String? ?? '',
      artist: media is Map ? _artistOf(media) : null,
      duration: seconds == null ? null : Duration(seconds: seconds),
      // QueueItem 自身の image が無いときは media_item 側を見る。
      image: MaImage.tryFrom(json['image']) ??
          (media is Map ? _imageOf(Map<String, dynamic>.from(media)) : null),
      uri: media is Map ? media['uri'] as String? : null,
      index: (json['index'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 再生の単位。MA の `PlayerQueue`。
///
/// **操作は必ずここへ送る**（プレイヤーへ直接送るとグループ再生で親に吸われる）。
@immutable
class MaQueue {
  const MaQueue({
    required this.queueId,
    required this.displayName,
    required this.active,
    required this.items,
    this.state = MaPlaybackState.idle,
    this.shuffleEnabled = false,
    this.repeatMode = MaRepeatMode.off,
    this.currentIndex,
    this.currentItem,
    this.nextItem,
    this.elapsed = Duration.zero,
    this.elapsedAt,
  });

  final String queueId;
  final String displayName;
  final bool active;

  /// キューに積まれている件数。
  final int items;

  final MaPlaybackState state;
  final bool shuffleEnabled;
  final MaRepeatMode repeatMode;
  final int? currentIndex;
  final MaQueueItem? currentItem;
  final MaQueueItem? nextItem;

  /// [elapsedAt] 時点での経過時間。そのまま出すと止まって見える（§4.2）。
  final Duration elapsed;

  /// [elapsed] を受け取った端末側の時刻。サーバーの壁時計は使わない
  /// （時計がずれていると経過時間が飛ぶ）。
  final DateTime? elapsedAt;

  bool get isPlaying => state == MaPlaybackState.playing;

  /// いまの経過時間。再生中だけ、受け取ってからの経過ぶんを足す。
  Duration correctedElapsed(DateTime now) {
    final at = elapsedAt;
    if (!isPlaying || at == null) return elapsed;
    final delta = now.difference(at);
    return delta.isNegative ? elapsed : elapsed + delta;
  }

  static MaQueue fromJson(Map<String, dynamic> json, {DateTime? now}) {
    final seconds = (json['elapsed_time'] as num?)?.toDouble() ?? 0;
    return MaQueue(
      queueId: json['queue_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      active: json['active'] == true,
      items: (json['items'] as num?)?.toInt() ?? 0,
      state: MaPlaybackState.parse(json['state']),
      shuffleEnabled: json['shuffle_enabled'] == true,
      repeatMode: MaRepeatMode.parse(json['repeat_mode']),
      currentIndex: (json['current_index'] as num?)?.toInt(),
      currentItem: MaQueueItem.tryFrom(json['current_item']),
      nextItem: MaQueueItem.tryFrom(json['next_item']),
      elapsed: Duration(milliseconds: (seconds * 1000).round()),
      elapsedAt: now ?? DateTime.now(),
    );
  }

  MaQueue copyWith({Duration? elapsed, DateTime? elapsedAt}) => MaQueue(
    queueId: queueId,
    displayName: displayName,
    active: active,
    items: items,
    state: state,
    shuffleEnabled: shuffleEnabled,
    repeatMode: repeatMode,
    currentIndex: currentIndex,
    currentItem: currentItem,
    nextItem: nextItem,
    elapsed: elapsed ?? this.elapsed,
    elapsedAt: elapsedAt ?? this.elapsedAt,
  );
}

/// 検索結果の 1 件。`uri` があれば `player_queues/play_media` に投げられる。
@immutable
class MaMediaItem {
  const MaMediaItem({
    required this.uri,
    required this.name,
    required this.mediaType,
    this.artist,
    this.duration,
    this.image,
  });

  final String uri;
  final String name;

  /// `track` / `album` / `artist` / `playlist` など。
  final String mediaType;
  final String? artist;
  final Duration? duration;
  final MaImage? image;

  /// どのプロバイダのものか（`qobuz` / `spotify` / `library` …）。
  String get provider {
    final scheme = uri.split('://').first;
    return scheme == uri ? '' : scheme;
  }

  static MaMediaItem? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final uri = json['uri'];
    final name = json['name'];
    if (uri is! String || uri.isEmpty || name is! String) return null;
    final seconds = (json['duration'] as num?)?.round();
    return MaMediaItem(
      uri: uri,
      name: name,
      mediaType: json['media_type'] as String? ?? 'unknown',
      artist: _artistOf(json),
      duration: seconds == null || seconds == 0
          ? null
          : Duration(seconds: seconds),
      image: _imageOf(json),
    );
  }
}

/// `music/search` の応答。
@immutable
class MaSearchResults {
  const MaSearchResults({
    this.tracks = const [],
    this.albums = const [],
    this.playlists = const [],
    this.artists = const [],
  });

  final List<MaMediaItem> tracks;
  final List<MaMediaItem> albums;
  final List<MaMediaItem> playlists;
  final List<MaMediaItem> artists;

  bool get isEmpty =>
      tracks.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty;

  static MaSearchResults fromJson(Map<String, dynamic> json) => MaSearchResults(
    tracks: _list(json['tracks']),
    albums: _list(json['albums']),
    playlists: _list(json['playlists']),
    artists: _list(json['artists']),
  );

  static List<MaMediaItem> _list(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map(MaMediaItem.tryFrom)
        .whereType<MaMediaItem>()
        .toList(growable: false);
  }
}

/// `artists` は `Artist` の配列だったり `ItemMapping` の配列だったりする。
/// どちらも `name` は持っているので、そこだけ拾って `/` で繋ぐ。
String? _artistOf(Map json) {
  final artists = json['artists'];
  if (artists is! List) {
    // トラックにアーティストが無いとき、アルバム側に付いていることがある。
    final album = json['album'];
    return album is Map ? _artistOf(album) : null;
  }
  final names = artists
      .whereType<Map>()
      .map((a) => a['name'])
      .whereType<String>()
      .where((n) => n.isNotEmpty);
  return names.isEmpty ? null : names.join('/');
}

/// 画像は `image`（ItemMapping）と `metadata.images`（MediaItem）の 2 か所に
/// 出る。トラックは自前の絵を持たないことが多いのでアルバムまで辿る。
MaImage? _imageOf(Map<String, dynamic> json) {
  final direct = MaImage.tryFrom(json['image']);
  if (direct != null) return direct;

  final metadata = json['metadata'];
  if (metadata is Map) {
    final images = metadata['images'];
    if (images is List) {
      // thumb を優先。無ければ先頭。
      final thumb = images
          .whereType<Map>()
          .where((i) => i['type'] == 'thumb')
          .toList();
      final picked = thumb.isNotEmpty
          ? thumb.first
          : (images.isEmpty ? null : images.first);
      final image = MaImage.tryFrom(picked);
      if (image != null) return image;
    }
  }

  final album = json['album'];
  if (album is Map) return _imageOf(Map<String, dynamic>.from(album));
  return null;
}
