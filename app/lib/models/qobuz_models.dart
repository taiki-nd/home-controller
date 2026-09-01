import 'package:flutter/foundation.dart';

/// Qobuz REST v0.2 の JSON から、画面が使う分だけ削って持つ
/// （`docs/qobuz-wiim-integration.md` §4）。
///
/// **この API はパートナー限定で、公開されたスキーマが無い。** 項目は実際の
/// 応答を見て決めているので、増やすときは「画面のどこに出るか」が言えるものだけ
/// にする。欠けていても落ちないよう、必須は id と表示名だけにしてある。

/// ストリームの形式。`track/getFileUrl` の `format_id`。
///
/// **27 を頼んでも 27 が返るとは限らない。** 音源とサブスクの上限で落ちるので、
/// 実際に何が返ったかは [QobuzFileUrl.formatId] を見る。
enum QobuzFormat {
  /// MP3 320kbps。ロスレスが要らない場面向け（このアプリでは使わない）。
  mp3(5, 'MP3 320'),

  /// FLAC 16bit/44.1kHz。CD 品質。
  cd(6, 'FLAC 16/44.1'),

  /// FLAC 24bit ≤96kHz。
  hires96(7, 'FLAC 24/96'),

  /// FLAC 24bit >96kHz（〜192kHz）。
  hires192(27, 'FLAC 24/192');

  const QobuzFormat(this.id, this.label);

  final int id;
  final String label;

  static QobuzFormat? byId(int? id) {
    for (final format in QobuzFormat.values) {
      if (format.id == id) return format;
    }
    return null;
  }
}

/// トラック 1 曲。
@immutable
class QobuzTrack {
  const QobuzTrack({
    required this.id,
    required this.title,
    this.version,
    this.artist,
    this.albumTitle,
    this.imageUrl,
    this.largeImageUrl,
    this.duration,
    this.streamable = true,
    this.hiresStreamable = false,
    this.maxBitDepth,
    this.maxSamplingRate,
    this.isrc,
    this.playlistTrackId,
  });

  final int id;
  final String title;

  /// `Remastered` / `Live` など。同じ曲名の別音源を見分ける唯一の手掛かり。
  final String? version;

  final String? artist;
  final String? albumTitle;

  /// 一覧のサムネと **WiiM 本体に渡すぶん**（`small` = 230px）。
  final String? imageUrl;

  /// 再生画面のアートワーク用（`large` = 600px）。無ければ null。
  /// 直接は使わず [displayImageUrl] を通す。
  final String? largeImageUrl;

  final Duration? duration;

  /// 契約と地域で鳴らせない曲がある。**false のものはキューに入れない。**
  final bool streamable;

  /// ハイレゾで鳴らせるか（§3 の落とし穴 6）。
  final bool hiresStreamable;

  final int? maxBitDepth;

  /// kHz。Qobuz は `44.1` のような小数で返す。
  final double? maxSamplingRate;

  /// **同一楽曲の別バージョン照合はこれの完全一致だけを信じる**（§3 の
  /// 落とし穴 7）。曲名＋再生時間でのマッチングはクラシックで別演奏を掴む。
  final String? isrc;

  /// プレイリスト内の行 ID。**`id` とは別物**（§3 の落とし穴 1）。
  /// 削除と並べ替えはこちらを使う。プレイリスト経由で取ったときだけ入る。
  final int? playlistTrackId;

  /// 大きく出すときの画像。**アプリ内の再生画面だけがこれを使う。**
  /// `large` が無い応答もあるので [imageUrl] に落ちる。
  String? get displayImageUrl => largeImageUrl ?? imageUrl;

  /// 画面に出す曲名。`version` があれば括弧で添える。
  String get displayTitle {
    final version = this.version;
    if (version == null || version.isEmpty) return title;
    return '$title（$version）';
  }

  /// `24bit / 96kHz`。分からなければ null。
  String? get qualityLabel {
    final depth = maxBitDepth;
    final rate = maxSamplingRate;
    if (depth == null || rate == null) return null;
    final rateText = rate == rate.roundToDouble()
        ? '${rate.round()}'
        : rate.toStringAsFixed(1);
    return '${depth}bit / ${rateText}kHz';
  }

  static QobuzTrack? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = (json['id'] as num?)?.toInt();
    if (id == null) return null;
    final album = json['album'];
    final albumJson = album is Map ? Map<String, dynamic>.from(album) : null;
    final seconds = (json['duration'] as num?)?.toInt();
    return QobuzTrack(
      id: id,
      title: json['title'] as String? ?? '',
      version: json['version'] as String?,
      artist:
          _performerOf(json) ??
          (albumJson == null ? null : _artistOf(albumJson)),
      albumTitle: albumJson?['title'] as String?,
      imageUrl: albumJson == null ? null : _imageOf(albumJson),
      largeImageUrl: albumJson == null ? null : _largeImageOf(albumJson),
      duration: seconds == null || seconds == 0
          ? null
          : Duration(seconds: seconds),
      // 欠けているときは鳴らせる前提で置く。実際に駄目なら getFileUrl が
      // restrictions を返すので、そこで弾ける。
      streamable: json['streamable'] != false,
      hiresStreamable: json['hires_streamable'] == true,
      maxBitDepth: (json['maximum_bit_depth'] as num?)?.toInt(),
      maxSamplingRate: (json['maximum_sampling_rate'] as num?)?.toDouble(),
      isrc: json['isrc'] as String?,
      playlistTrackId: (json['playlist_track_id'] as num?)?.toInt(),
    );
  }

  QobuzTrack copyWith({int? playlistTrackId}) => QobuzTrack(
    id: id,
    title: title,
    version: version,
    artist: artist,
    albumTitle: albumTitle,
    imageUrl: imageUrl,
    largeImageUrl: largeImageUrl,
    duration: duration,
    streamable: streamable,
    hiresStreamable: hiresStreamable,
    maxBitDepth: maxBitDepth,
    maxSamplingRate: maxSamplingRate,
    isrc: isrc,
    playlistTrackId: playlistTrackId ?? this.playlistTrackId,
  );
}

/// アルバム。
@immutable
class QobuzAlbum {
  const QobuzAlbum({
    required this.id,
    required this.title,
    this.artist,
    this.imageUrl,
    this.tracksCount = 0,
    this.hires = false,
    this.releasedAt,
    this.tracks = const [],
  });

  final String id;
  final String title;
  final String? artist;
  final String? imageUrl;
  final int tracksCount;
  final bool hires;
  final String? releasedAt;

  /// `album/get` で引いたときだけ入る。検索結果の時点では空。
  final List<QobuzTrack> tracks;

  static QobuzAlbum? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final tracks = json['tracks'];
    return QobuzAlbum(
      id: id,
      title: json['title'] as String? ?? '',
      artist: _artistOf(json),
      imageUrl: _imageOf(json),
      tracksCount: (json['tracks_count'] as num?)?.toInt() ?? 0,
      hires: json['hires_streamable'] == true || json['hires'] == true,
      releasedAt: json['release_date_original'] as String?,
      tracks: tracks is Map ? _tracks(tracks['items']) : const [],
    );
  }
}

/// アーティスト。
@immutable
class QobuzArtist {
  const QobuzArtist({
    required this.id,
    required this.name,
    this.imageUrl,
    this.albumsCount = 0,
  });

  final int id;
  final String name;
  final String? imageUrl;
  final int albumsCount;

  static QobuzArtist? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = (json['id'] as num?)?.toInt();
    if (id == null) return null;
    return QobuzArtist(
      id: id,
      name: json['name'] as String? ?? '',
      imageUrl: _imageOf(json),
      albumsCount: (json['albums_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// プレイリスト。
@immutable
class QobuzPlaylist {
  const QobuzPlaylist({
    required this.id,
    required this.name,
    this.description,
    this.owner,
    this.tracksCount = 0,
    this.imageUrl,
    this.isOwner = false,
    this.tracks = const [],
  });

  final int id;
  final String name;
  final String? description;
  final String? owner;
  final int tracksCount;
  final String? imageUrl;

  /// 自分のものか。**編集ボタンを出すかの判断に使う。**
  /// 他人のプレイリストに addTracks を投げてもエラーになるだけ。
  final bool isOwner;

  /// `playlist/get?extra=tracks` で引いたときだけ入る。
  final List<QobuzTrack> tracks;

  static QobuzPlaylist? tryFrom(Object? raw, {int? ownerUserId}) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = (json['id'] as num?)?.toInt();
    if (id == null) return null;
    final owner = json['owner'];
    final ownerJson = owner is Map ? Map<String, dynamic>.from(owner) : null;
    final ownerId = (ownerJson?['id'] as num?)?.toInt();
    final tracks = json['tracks'];
    return QobuzPlaylist(
      id: id,
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      owner: ownerJson?['name'] as String?,
      tracksCount: (json['tracks_count'] as num?)?.toInt() ?? 0,
      imageUrl: _playlistImageOf(json),
      isOwner: ownerUserId != null && ownerId == ownerUserId,
      tracks: tracks is Map ? _tracks(tracks['items']) : const [],
    );
  }

  QobuzPlaylist copyWith({List<QobuzTrack>? tracks}) => QobuzPlaylist(
    id: id,
    name: name,
    description: description,
    owner: owner,
    tracksCount: tracks?.length ?? tracksCount,
    imageUrl: imageUrl,
    isOwner: isOwner,
    tracks: tracks ?? this.tracks,
  );
}

/// 検索結果。タブごとに分かれて出る。
@immutable
class QobuzSearchResults {
  const QobuzSearchResults({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final List<QobuzTrack> tracks;
  final List<QobuzAlbum> albums;
  final List<QobuzArtist> artists;

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty;
}

/// お気に入り。
@immutable
class QobuzFavorites {
  const QobuzFavorites({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final List<QobuzTrack> tracks;
  final List<QobuzAlbum> albums;
  final List<QobuzArtist> artists;

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty;
}

/// `track/getFileUrl` の応答。
///
/// **URL には失効時刻が入っている**（`etsp`、おおよそ 24 時間）。
/// プレイリスト全曲ぶんを先に取ると後半が失効するので、**再生直前に取る**
/// （§3）。[expiresAt] は取れたときだけ入る。
@immutable
class QobuzFileUrl {
  const QobuzFileUrl({
    required this.trackId,
    required this.url,
    this.formatId,
    this.mimeType,
    this.bitDepth,
    this.samplingRate,
    this.expiresAt,
  });

  final int trackId;
  final String url;
  final int? formatId;
  final String? mimeType;
  final int? bitDepth;
  final double? samplingRate;
  final DateTime? expiresAt;

  /// 実際に返ってきた品質。頼んだ format_id とは限らない。
  String get qualityLabel {
    final depth = bitDepth;
    final rate = samplingRate;
    if (depth != null && rate != null) {
      final rateText = rate == rate.roundToDouble()
          ? '${rate.round()}'
          : rate.toStringAsFixed(1);
      return '${depth}bit / ${rateText}kHz';
    }
    return QobuzFormat.byId(formatId)?.label ?? '不明';
  }

  static QobuzFileUrl? tryFrom(Object? raw, {required int trackId}) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    // 失効時刻はクエリの etsp（UNIX 秒）。無い世代もあるので必須にしない。
    final etsp = Uri.tryParse(url)?.queryParameters['etsp'];
    final epoch = etsp == null ? null : int.tryParse(etsp);
    return QobuzFileUrl(
      trackId: trackId,
      url: url,
      formatId: (json['format_id'] as num?)?.toInt(),
      mimeType: json['mime_type'] as String?,
      bitDepth: (json['bit_depth'] as num?)?.toInt(),
      samplingRate: (json['sampling_rate'] as num?)?.toDouble(),
      expiresAt: epoch == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
    );
  }
}

/// ログイン結果。
@immutable
class QobuzUser {
  const QobuzUser({
    required this.id,
    required this.token,
    this.displayName,
    this.email,
    this.subscription,
  });

  final int id;

  /// `X-User-Auth-Token`。**ログに出さない。**
  final String token;

  final String? displayName;
  final String? email;

  /// `credential.label`（`Studio` など）。ハイレゾが鳴るかの目安。
  final String? subscription;
}

List<QobuzTrack> _tracks(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .map(QobuzTrack.tryFrom)
      .whereType<QobuzTrack>()
      .toList(growable: false);
}

/// `performer` → `composer` の順に見る。どちらも無ければ null。
String? _performerOf(Map<String, dynamic> json) {
  for (final key in const ['performer', 'composer']) {
    final value = json[key];
    if (value is Map) {
      final name = value['name'];
      if (name is String && name.isNotEmpty) return name;
    }
  }
  return null;
}

String? _artistOf(Map<String, dynamic> json) {
  final artist = json['artist'];
  if (artist is Map) {
    final name = artist['name'];
    if (name is String && name.isNotEmpty) return name;
  }
  return null;
}

/// 画像は `image: {small, thumbnail, large, back}` で来る（small=230、
/// thumbnail=50、large=600 px）。
///
/// **こちらは small 止まり。** 一覧のサムネは 62px までなので足りるし、
/// **WiiM 本体に渡すのもこれ**（`artUrl`）——本体側で大きい絵を掴ませて
/// 表示が崩れるのを避けたいので、機器に出す URL はここから変えない。
/// 再生画面の大きいアートワークは [_largeImageOf] を使う。
String? _imageOf(Map<String, dynamic> json) {
  final image = json['image'];
  if (image is Map) {
    for (final key in const ['small', 'thumbnail', 'large']) {
      final url = image[key];
      if (url is String && url.isNotEmpty) return url;
    }
  }
  if (image is String && image.isNotEmpty) return image;
  return null;
}

/// プレイリストのサムネ。
///
/// **プレイリストには `image` が来ない。** 代わりに複数のキーに URL の配列が
/// 入る。編集部が作ったものには横長の `image_rectangle` が付くが、自分で
/// 作ったプレイリストには付かない（キー自体が無いか、空配列）。そちらは
/// 収録アルバムのジャケットを並べた `images300` / `images150` / `images`
/// （それぞれ 300 / 150 / 50px）だけが入る。
///
/// 以前は `image_rectangle` しか見ずに、外れたら `image` を探しにいって
/// いたので、**自分のプレイリストのサムネがまるごと出なかった**。
/// 大きいほうから順に落として、最後の保険で `image` を見る。
String? _playlistImageOf(Map<String, dynamic> json) {
  for (final key in const [
    'image_rectangle',
    'images300',
    'images150',
    'images',
  ]) {
    final value = json[key];
    if (value is List) {
      for (final url in value) {
        if (url is String && url.isNotEmpty) return url;
      }
    }
    if (value is String && value.isNotEmpty) return value;
  }
  return _imageOf(json);
}

/// 再生画面のアートワーク用。`large`（600px）だけを見る。
///
/// **小さいほうへ落とさない。** 見つからなければ null を返して、呼ぶ側
/// （[QobuzTrack.displayImageUrl]）で [_imageOf] の結果に落とす。ここで
/// thumbnail まで拾うと、50px を全画面に引き伸ばすことになる。
String? _largeImageOf(Map<String, dynamic> json) {
  final image = json['image'];
  if (image is Map) {
    final url = image['large'];
    if (url is String && url.isNotEmpty) return url;
  }
  return null;
}
