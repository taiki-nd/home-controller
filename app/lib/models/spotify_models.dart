/// Spotify Web API のレスポンスから、このアプリが必要とする分だけを取り出す。
/// アプリはステートレス（設計メモ §1）なので、モデルは全て「今取ってきた JSON の写し」。
library;

class SpotifyImage {
  const SpotifyImage({required this.url, this.width, this.height});

  final String url;
  final int? width;
  final int? height;

  static SpotifyImage? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final url = json['url'];
    if (url is! String) return null;
    return SpotifyImage(
      url: url,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }

  /// 画像は大きい順で返ってくる。用途に応じて幅で選ぶ。
  static SpotifyImage? pick(List<dynamic>? images, {int minWidth = 0}) {
    if (images == null || images.isEmpty) return null;
    final parsed = images
        .whereType<Map<String, dynamic>>()
        .map(SpotifyImage.fromJson)
        .whereType<SpotifyImage>()
        .toList();
    if (parsed.isEmpty) return null;
    parsed.sort((a, b) => (a.width ?? 0).compareTo(b.width ?? 0));
    for (final image in parsed) {
      if ((image.width ?? 0) >= minWidth) return image;
    }
    return parsed.last;
  }
}

class Track {
  const Track({
    required this.id,
    required this.uri,
    required this.name,
    required this.artists,
    required this.albumName,
    required this.durationMs,
    this.artworkUrl,
    this.smallArtworkUrl,
  });

  final String id;
  final String uri;
  final String name;
  final String artists;
  final String albumName;
  final int durationMs;
  final String? artworkUrl;
  final String? smallArtworkUrl;

  static Track? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    // ポッドキャストのエピソードが混ざると type == 'episode' で uri 形状が違う。
    // このアプリは曲だけを扱うので弾く。
    final uri = json['uri'];
    if (uri is! String) return null;
    final album = json['album'] as Map<String, dynamic>?;
    final images = album?['images'] as List<dynamic>?;
    final artistList = (json['artists'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((a) => a['name'])
        .whereType<String>()
        .toList();
    return Track(
      id: json['id'] as String? ?? uri,
      uri: uri,
      name: json['name'] as String? ?? '—',
      artists: artistList.isEmpty ? '' : artistList.join(', '),
      albumName: album?['name'] as String? ?? '',
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      artworkUrl: SpotifyImage.pick(images, minWidth: 600)?.url,
      smallArtworkUrl: SpotifyImage.pick(images, minWidth: 160)?.url,
    );
  }
}

class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.uri,
    required this.name,
    required this.ownerName,
    required this.trackCount,
    this.artworkUrl,
  });

  final String id;
  final String uri;
  final String name;
  final String ownerName;
  final int trackCount;
  final String? artworkUrl;

  /// デザインの `pl.desc`（"You · 42 songs"）に相当する行。
  String get subtitle => '$ownerName · $trackCount songs';

  static PlaylistSummary? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    // /me/playlists は稀に null 要素を返すことがある。
    final uri = json['uri'];
    if (uri is! String) return null;
    return PlaylistSummary(
      id: json['id'] as String? ?? uri,
      uri: uri,
      name: json['name'] as String? ?? 'Untitled',
      ownerName:
          (json['owner'] as Map<String, dynamic>?)?['display_name'] as String? ??
          'Unknown',
      trackCount:
          ((json['tracks'] as Map<String, dynamic>?)?['total'] as num?)
              ?.toInt() ??
          0,
      artworkUrl: SpotifyImage.pick(
        json['images'] as List<dynamic>?,
        minWidth: 160,
      )?.url,
    );
  }
}

/// `GET /me/following?type=artist` の 1 件。新譜の母集団に使う。
class FollowedArtist {
  const FollowedArtist({
    required this.id,
    required this.uri,
    required this.name,
    this.artworkUrl,
  });

  final String id;
  final String uri;
  final String name;
  final String? artworkUrl;

  /// MusicBrainz 側で MBID を引くためのキー。
  ///
  /// MusicBrainz はアーティストに Spotify の URL を関連として持っているので、
  /// `GET /ws/2/url?resource=<これ>&inc=artist-rels` で名寄せ無しに MBID が
  /// 引ける。**ただし関連はボランティア入力なので全員には付いていない。**
  String get musicBrainzLookupUrl => 'https://open.spotify.com/artist/$id';

  static FollowedArtist? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id'];
    if (id is! String) return null;
    return FollowedArtist(
      id: id,
      uri: json['uri'] as String? ?? 'spotify:artist:$id',
      name: json['name'] as String? ?? 'Unknown artist',
      artworkUrl: SpotifyImage.pick(
        json['images'] as List<dynamic>?,
        minWidth: 160,
      )?.url,
    );
  }
}

/// `GET /search?type=album` の 1 件。
///
/// MusicBrainz の新譜（[NewRelease]）を Spotify で鳴らすために引き当てる先。
/// Spotify は MBID を知らないので、これは**文字列検索の当たり**でしかない。
class SpotifyAlbumMatch {
  const SpotifyAlbumMatch({
    required this.id,
    required this.uri,
    required this.name,
    required this.artists,
    required this.totalTracks,
    this.artworkUrl,
    this.releaseDate,
  });

  final String id;
  final String uri;
  final String name;
  final String artists;
  final int totalTracks;
  final String? artworkUrl;
  final String? releaseDate;

  static SpotifyAlbumMatch? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final uri = json['uri'];
    if (uri is! String) return null;
    final artistList = (json['artists'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((a) => a['name'])
        .whereType<String>()
        .toList();
    return SpotifyAlbumMatch(
      id: json['id'] as String? ?? uri,
      uri: uri,
      name: json['name'] as String? ?? '—',
      artists: artistList.join(', '),
      totalTracks: (json['total_tracks'] as num?)?.toInt() ?? 0,
      artworkUrl: SpotifyImage.pick(
        json['images'] as List<dynamic>?,
        minWidth: 160,
      )?.url,
      releaseDate: json['release_date'] as String?,
    );
  }
}

enum SpotifyDeviceKind { speaker, tv, smartphone, computer, other }

class SpotifyDevice {
  const SpotifyDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.isActive,
    required this.isRestricted,
    this.volumePercent,
  });

  final String? id;
  final String name;
  final SpotifyDeviceKind kind;
  final bool isActive;
  final bool isRestricted;
  final int? volumePercent;

  String get kindLabel => switch (kind) {
    SpotifyDeviceKind.speaker => 'Speaker',
    SpotifyDeviceKind.tv => 'TV',
    SpotifyDeviceKind.smartphone => 'Smartphone',
    SpotifyDeviceKind.computer => 'Computer',
    SpotifyDeviceKind.other => 'Device',
  };

  static SpotifyDevice? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final raw = (json['type'] as String? ?? '').toLowerCase();
    return SpotifyDevice(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Unknown device',
      kind: switch (raw) {
        'speaker' || 'avr' || 'stb' || 'audio_dongle' => SpotifyDeviceKind.speaker,
        'tv' || 'castvideo' => SpotifyDeviceKind.tv,
        'smartphone' || 'tablet' => SpotifyDeviceKind.smartphone,
        'computer' => SpotifyDeviceKind.computer,
        _ => SpotifyDeviceKind.other,
      },
      isActive: json['is_active'] as bool? ?? false,
      isRestricted: json['is_restricted'] as bool? ?? false,
      volumePercent: (json['volume_percent'] as num?)?.toInt(),
    );
  }
}

/// `GET /me/player` の結果。204 のときは [PlaybackState.stopped] を使う。
class PlaybackState {
  const PlaybackState({
    required this.isPlaying,
    required this.progressMs,
    required this.shuffleState,
    required this.hasContent,
    this.track,
    this.device,
    this.contextUri,
  });

  /// 204 NO CONTENT。「停止中」であってエラーではない（設計メモ §5）。
  static const stopped = PlaybackState(
    isPlaying: false,
    progressMs: 0,
    shuffleState: false,
    hasContent: false,
  );

  final bool isPlaying;
  final int progressMs;
  final bool shuffleState;

  /// false なら 204（Spotify が「何も再生していない」と言っている）。
  final bool hasContent;
  final Track? track;
  final SpotifyDevice? device;
  final String? contextUri;

  static PlaybackState fromJson(Map<String, dynamic> json) {
    return PlaybackState(
      isPlaying: json['is_playing'] as bool? ?? false,
      progressMs: (json['progress_ms'] as num?)?.toInt() ?? 0,
      shuffleState: json['shuffle_state'] as bool? ?? false,
      hasContent: true,
      track: Track.fromJson(json['item'] as Map<String, dynamic>?),
      device: SpotifyDevice.fromJson(json['device'] as Map<String, dynamic>?),
      contextUri:
          (json['context'] as Map<String, dynamic>?)?['uri'] as String?,
    );
  }
}

/// `GET /me/player/queue`。currently_playing + queue（先読み最大 20 曲程度）。
class QueueSnapshot {
  const QueueSnapshot({required this.upcoming});

  static const empty = QueueSnapshot(upcoming: []);

  final List<Track> upcoming;

  static QueueSnapshot fromJson(Map<String, dynamic> json) {
    final raw = (json['queue'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Track.fromJson)
        .whereType<Track>()
        .toList();

    // 既知の不具合（設計メモ §4）: キューが少ないとき同じ曲でパディングして
    // 20 件に見せかけてくることがある。連続する同一 URI を畳んで無かったことにする。
    final folded = <Track>[];
    for (final track in raw) {
      if (folded.isNotEmpty && folded.last.uri == track.uri) continue;
      folded.add(track);
    }
    return QueueSnapshot(upcoming: folded);
  }
}

class SearchPage {
  const SearchPage({
    required this.tracks,
    required this.offset,
    required this.hasMore,
  });

  static const empty = SearchPage(tracks: [], offset: 0, hasMore: false);

  final List<Track> tracks;
  final int offset;
  final bool hasMore;

  static SearchPage fromJson(Map<String, dynamic> json) {
    final block = json['tracks'] as Map<String, dynamic>?;
    final items = (block?['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Track.fromJson)
        .whereType<Track>()
        .toList();
    final offset = (block?['offset'] as num?)?.toInt() ?? 0;
    final limit = (block?['limit'] as num?)?.toInt() ?? items.length;
    final total = (block?['total'] as num?)?.toInt() ?? 0;
    return SearchPage(
      tracks: items,
      offset: offset,
      // Development Mode の /search は limit 上限 10。次ページの有無は
      // total ではなく「limit いっぱい返ってきたか」で見るほうが安全。
      hasMore: items.length >= limit && offset + items.length < total,
    );
  }
}
