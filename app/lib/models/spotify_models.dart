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
    this.ownerId,
    this.collaborative = false,
  });

  final String id;
  final String uri;
  final String name;
  final String ownerName;
  final int trackCount;
  final String? artworkUrl;

  /// 所有者の Spotify user id。`/me/playlists` は他人のプレイリスト（フォロー中）も
  /// 返すので、曲を足せるかどうかはこれと自分の id を突き合わせて決める。
  final String? ownerId;

  /// コラボプレイリスト。所有者が他人でも書き込める。
  final bool collaborative;

  /// デザインの `pl.desc`（"You · 42 songs"）に相当する行。
  String get subtitle => '$ownerName · $trackCount songs';

  /// Spotify 自身が作るプレイリストの所有者 id。
  ///
  /// Discover Weekly / Daily Mix / Release Radar / Blend などがこれ。
  /// **本人のライブラリに並ぶが、誰も中身を書き換えられない**（403 Forbidden）。
  static const spotifyOwnerId = 'spotify';

  /// [userId] が曲を足したり消したりできるか。
  ///
  /// 自分の id が分からない（[userId] が null）ときは true を返す。
  /// 出せる導線を勝手に減らすより、Spotify に 403 を返させたほうが正しい。
  /// ただし Spotify 製だけは id が分からなくても確実に書けないので落とす。
  bool isEditableBy(String? userId) {
    if (ownerId == spotifyOwnerId) return false;
    if (collaborative) return true;
    if (userId == null || ownerId == null) return true;
    return ownerId == userId;
  }

  /// 曲数だけ差し替えた写し。追加・削除の直後にリストの "42 songs" を合わせる。
  PlaylistSummary withTrackCount(int value) => PlaylistSummary(
    id: id,
    uri: uri,
    name: name,
    ownerName: ownerName,
    trackCount: value < 0 ? 0 : value,
    artworkUrl: artworkUrl,
    ownerId: ownerId,
    collaborative: collaborative,
  );

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
      ownerId: (json['owner'] as Map<String, dynamic>?)?['id'] as String?,
      collaborative: json['collaborative'] == true,
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
    required String? name,
    required this.kind,
    required this.isActive,
    required this.isRestricted,
    this.volumePercent,
  }) : realName = name;

  final String? id;

  /// 信用できる表示名。Spotify が表示名を持っていないときは null。
  /// 表示には [name] を使う。
  final String? realName;

  final SpotifyDeviceKind kind;
  final bool isActive;
  final bool isRestricted;
  final int? volumePercent;

  /// 画面に出す名前。[realName] が無ければ既定文言に落とす。
  String get name => realName ?? 'Unknown device';

  /// Spotify が name にデバイス識別子を返してきたかどうか。
  ///
  /// Connect スピーカー（WiiM 等）は LAN 上の zeroconf で公式クライアントに
  /// 見つけてもらい、公式クライアントがバックエンドに登録して初めて表示名が
  /// 付く。それより前は `/me/player/devices` の name が識別子そのものになり、
  /// 画面には英数字の羅列が出る。名前として使えないので弾く。
  ///
  /// 誤検知を避けるため「16進だけで 24 文字以上」か「id と同一」に限る。
  /// 人が付ける名前がこの形になることは無い。
  static bool looksLikeIdentifier(String value, {String? id}) {
    if (id != null && value == id) return true;
    return RegExp(r'^[0-9a-fA-F]{24,}$').hasMatch(value);
  }

  /// キャッシュしておいた表示名を当てた複製。
  SpotifyDevice withName(String value) => SpotifyDevice(
    id: id,
    name: value,
    kind: kind,
    isActive: isActive,
    isRestricted: isRestricted,
    volumePercent: volumePercent,
  );

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
    final id = json['id'] as String?;
    final rawName = (json['name'] as String?)?.trim();
    return SpotifyDevice(
      id: id,
      name: rawName == null ||
              rawName.isEmpty ||
              looksLikeIdentifier(rawName, id: id)
          ? null
          : rawName,
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
