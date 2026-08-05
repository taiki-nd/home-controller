/// 新譜まわりのモデル。**ここだけ Spotify 由来ではない**（設計メモ §14）。
///
/// Spotify には新譜フィードが無い（`GET /browse/new-releases` は2026年2月に削除）
/// ため、リリース情報は MusicBrainz から取る。Spotify で鳴らすには
/// [NewRelease.spotifyAlbumUri] を解決する必要があり、それは行を押したときだけ行う。
library;

/// MusicBrainz の release-group 1 件。
class NewRelease {
  const NewRelease({
    required this.releaseGroupMbid,
    required this.title,
    required this.artistName,
    required this.artistMbids,
    this.releaseDate,
    this.primaryType,
    this.secondaryTypes = const [],
  });

  final String releaseGroupMbid;
  final String title;

  /// artist-credit を繋いだ表示名（"Panda Bear & Sonic Boom" 等）。
  final String artistName;
  final List<String> artistMbids;

  /// 日付が `2026` や `2026-08` のように粗いことがあるので null もあり得る。
  final DateTime? releaseDate;
  final String? primaryType;
  final List<String> secondaryTypes;

  /// Cover Art Archive。**Spotify のアートワークではない。**
  ///
  /// 画像が無い release-group では 404 になるので、表示側は必ずフォールバックを
  /// 持つこと（[Artwork] の errorBuilder が受ける）。
  String get coverArtUrl =>
      'https://coverartarchive.org/release-group/$releaseGroupMbid/front-250';

  /// `Album` / `Single` / `Album · Remix`。
  ///
  /// シングルとリミックスも新譜として拾うので、一次タイプだけだと
  /// リミックス盤が普通のアルバムと見分けられない。
  String? get typeLabel {
    final parts = [?primaryType, ...secondaryTypes];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  bool isUpcoming(DateTime now) {
    final date = releaseDate;
    if (date == null) return false;
    return date.isAfter(DateTime(now.year, now.month, now.day));
  }

  String dateLabel(DateTime now) {
    final date = releaseDate;
    if (date == null) return '発売日不明';
    final today = DateTime(now.year, now.month, now.day);
    final days = date.difference(today).inDays;
    if (days == 0) return '今日';
    if (days == 1) return '明日';
    if (days > 1) return 'あと$days日';
    if (days == -1) return '昨日';
    return '${-days}日前';
  }

  /// `2026-08-14` / `2026-08` / `2026` のいずれも来る。
  /// 粒度が粗いものは「その月/年の 1 日」に寄せず null にする。日付を勝手に
  /// でっち上げると「あと N 日」が嘘になるため。
  static DateTime? parseDate(String? raw) {
    if (raw == null) return null;
    final parts = raw.split('-');
    if (parts.length < 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static NewRelease? fromReleaseGroupJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id'];
    if (id is! String) return null;

    // artist-credit は [{name, joinphrase, artist:{id}}, ...]。
    // joinphrase を挟んで繋ぐと " & " や " feat. " が正しく再現される。
    final credits = (json['artist-credit'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>();
    final buffer = StringBuffer();
    final mbids = <String>[];
    for (final credit in credits) {
      buffer
        ..write(credit['name'] as String? ?? '')
        ..write(credit['joinphrase'] as String? ?? '');
      final artist = credit['artist'] as Map<String, dynamic>?;
      final mbid = artist?['id'];
      if (mbid is String) mbids.add(mbid);
    }

    return NewRelease(
      releaseGroupMbid: id,
      title: json['title'] as String? ?? '—',
      artistName: buffer.toString().trim().isEmpty
          ? 'Unknown artist'
          : buffer.toString().trim(),
      artistMbids: mbids,
      releaseDate: parseDate(json['first-release-date'] as String?),
      primaryType: json['primary-type'] as String?,
      secondaryTypes: (json['secondary-types'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }
}

/// フォロー中アーティストのうち何人を MusicBrainz に繋げられたか。
///
/// Spotify URL の関連はボランティア入力なので**全員には付いていない**
/// （設計メモ §14）。取りこぼしを黙って捨てると「なぜか出ない新譜」になるので、
/// 数を数えて UI に出す。
class MbCoverage {
  const MbCoverage({required this.followed, required this.resolved});

  static const empty = MbCoverage(followed: 0, resolved: 0);

  final int followed;
  final int resolved;

  int get missing => followed - resolved;
  double get ratio => followed == 0 ? 0 : resolved / followed;
}
