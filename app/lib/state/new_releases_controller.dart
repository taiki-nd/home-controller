import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/release_models.dart';
import '../models/spotify_models.dart';
import '../services/musicbrainz_api.dart';
import '../services/spotify_api.dart';

enum NewReleasesStatus { idle, loading, ready, failed }

/// 「New」タブ（設計メモ §14）。
///
/// **母集団は Spotify のフォロー一覧、リリース情報は MusicBrainz。**
/// [PlayerController] とは寿命もポーリングも別物なので混ぜていない。
///
/// キャッシュは持たない。フォロー200人でも Spotify 4 + MusicBrainz 6 程度で
/// 済む（どちらもバッチで潰せる）ので、起動ごとに取り直しても安い。
class NewReleasesController extends ChangeNotifier {
  NewReleasesController(
    this._spotify,
    this._musicBrainz, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SpotifyApi _spotify;
  final MusicBrainzApi _musicBrainz;
  final DateTime Function() _now;

  /// 遡る日数。ここより古いものは「新譜」ではない。
  static const pastDays = 30;

  /// 先読みする日数。**未発売のリリースが取れるのが MusicBrainz を使う利点。**
  static const futureDays = 90;

  NewReleasesStatus _status = NewReleasesStatus.idle;
  List<NewRelease> _releases = const [];
  MbCoverage _coverage = MbCoverage.empty;
  String? _error;
  bool _disposed = false;

  /// 解決できなかったアーティスト名。「なぜか出ない新譜」の説明に使う。
  List<String> _unresolvedArtists = const [];

  /// artist MBID → Spotify の artist id。
  ///
  /// **新譜を引くのに使った対応を捨てずに残しておく。** 行を押したとき、
  /// 「この盤を出したのは Spotify のどのアーティストか」がこれで確定するので、
  /// 名前で世界中から探さずに済む（[ReleaseResolver] 参照）。
  Map<String, String> _spotifyArtistIdByMbid = const {};

  NewReleasesStatus get status => _status;
  List<NewRelease> get releases => _releases;
  MbCoverage get coverage => _coverage;
  String? get error => _error;
  List<String> get unresolvedArtists => _unresolvedArtists;

  bool get isLoading => _status == NewReleasesStatus.loading;

  /// 未発売ぶん。UI で「Coming」として先頭に出す。
  List<NewRelease> get upcoming {
    final now = _now();
    return _releases.where((r) => r.isUpcoming(now)).toList();
  }

  /// この新譜を出したアーティストの Spotify id。
  ///
  /// フォローしていない共作相手は MBID しか分からないので落ちる（その盤は
  /// フォローしている側の棚にも並ぶので、それで足りる）。
  List<String> spotifyArtistIdsOf(NewRelease release) => release.artistMbids
      .map((mbid) => _spotifyArtistIdByMbid[mbid])
      .whereType<String>()
      .toList();

  List<NewRelease> get released {
    final now = _now();
    return _releases.where((r) => !r.isUpcoming(now)).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// タブを開いたときに一度だけ走る。[force] で明示的に取り直す。
  Future<void> load({bool force = false}) async {
    if (_disposed || isLoading) return;
    if (!force && _status == NewReleasesStatus.ready) return;

    _status = NewReleasesStatus.loading;
    _error = null;
    notifyListeners();

    try {
      // 1. 母集団。順序に意味は無い（[SpotifyApi.followedArtists] 参照）。
      final followed = await _spotify.followedArtists();
      if (_disposed) return;
      if (followed.isEmpty) {
        _releases = const [];
        _coverage = MbCoverage.empty;
        _unresolvedArtists = const [];
        _status = NewReleasesStatus.ready;
        notifyListeners();
        return;
      }

      // 2. Spotify のアーティストURL → MBID。名寄せは不要だが、
      //    関連が付いていないアーティストはここで落ちる。
      final mbidByUrl = await _musicBrainz.artistMbidsBySpotifyUrl(
        followed.map((a) => a.musicBrainzLookupUrl).toList(),
      );
      if (_disposed) return;

      final resolved = <String>[];
      final unresolved = <String>[];
      final spotifyIdByMbid = <String, String>{};
      for (final artist in followed) {
        final mbid = mbidByUrl[artist.musicBrainzLookupUrl];
        if (mbid == null) {
          unresolved.add(artist.name);
        } else {
          resolved.add(mbid);
          spotifyIdByMbid[mbid] = artist.id;
        }
      }
      _spotifyArtistIdByMbid = spotifyIdByMbid;
      _coverage = MbCoverage(
        followed: followed.length,
        resolved: resolved.length,
      );
      unresolved.sort();
      _unresolvedArtists = unresolved;
      debugLogCoverage(_coverage);

      // 3. 期間を切ってリリースを引く。
      final now = _now();
      final today = DateTime(now.year, now.month, now.day);
      final found = await _musicBrainz.releaseGroups(
        artistMbids: resolved,
        from: today.subtract(const Duration(days: pastDays)),
        to: today.add(const Duration(days: futureDays)),
      );
      if (_disposed) return;

      _releases = _sort(found, today);
      _status = NewReleasesStatus.ready;
    } on SpotifyScopeException catch (e) {
      // 再連携バナー側の担当。ここでは「まだ取れない」とだけ示す。
      _fail(e.message);
    } on SpotifyApiException catch (e) {
      _fail(e.message);
    } on MusicBrainzException catch (e) {
      _fail(e.message);
    } catch (e) {
      debugPrint('new releases load failed: $e');
      _fail('新譜を取得できませんでした');
    }
    if (!_disposed) notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    // 一度でも取れているなら、それは残したまま失敗だけ伝える。
    _status = _releases.isEmpty
        ? NewReleasesStatus.failed
        : NewReleasesStatus.ready;
  }

  /// 未発売を先に「近い順」、発売済みをその後に「新しい順」。
  ///
  /// 全体を日付の降順にすると、いちばん先の未発売が最上段に来てしまい
  /// 「次に何が出るか」が読めない。
  static List<NewRelease> _sort(List<NewRelease> releases, DateTime today) {
    final upcoming = <NewRelease>[];
    final past = <NewRelease>[];
    for (final release in releases) {
      (release.isUpcoming(today) ? upcoming : past).add(release);
    }
    upcoming.sort((a, b) => _compareDate(a, b));
    past.sort((a, b) => _compareDate(b, a));
    return [...upcoming, ...past];
  }

  /// 日付不明は末尾に寄せる。
  static int _compareDate(NewRelease a, NewRelease b) {
    final x = a.releaseDate;
    final y = b.releaseDate;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }
}

/// 新譜の行を Spotify で鳴らすための解決。
///
/// **全文検索（`/search?type=album`）は使わない。** 関連度順に並ぶだけなので、
/// Spotify にまだ無い新譜や表記の食い違う盤では、クエリの片側しか合っていない
/// 無関係な盤が平気で 1 位に来る。それを返すと「押したら全然違う曲が鳴る」に
/// なり、しかも呼び出し側からは成功と区別がつかない。
///
/// 代わりに **ID で辿れる経路を 2 本使い、どちらも外れたら null を返す**:
///
/// 1. そのアーティストの Spotify の棚（`/artists/{id}/albums`）の中だけで
///    タイトルを突き合わせる。**候補が閉じているので別アーティストを掴む事故が
///    原理的に起きない。** アーティストの id は、新譜を引くのに使った
///    `Spotify URL → artist MBID` の対応を逆に辿れば分かる
///    （[NewReleasesController.spotifyArtistIdsOf]）。
/// 2. MusicBrainz がリリースに持っている配信リンクから Spotify のアルバム id を
///    直接拾う（[MusicBrainzApi.spotifyAlbumIds]）。**名寄せが要らない。**
///    1 が外れるのは MB と Spotify でタイトルの表記系が違うときで、そこは
///    こちらがちょうど強い。付いていない盤も多いので後段に置く。
///
/// リスト全体ではなく**押された行だけ**解決するのは、この 1〜2 リクエストを
/// 起動時に 200 人ぶん払わないため（`MusicBrainzApi` の冒頭も参照）。
class ReleaseResolver {
  const ReleaseResolver(this._spotify, this._musicBrainz);

  final SpotifyApi _spotify;
  final MusicBrainzApi _musicBrainz;

  /// 見つからなければ null。
  ///
  /// [spotifyArtistIds] は [NewReleasesController.spotifyArtistIdsOf] から渡す。
  /// 空でも 2 本目の経路だけは試す。
  Future<SpotifyAlbumMatch?> resolve(
    NewRelease release, {
    Iterable<String> spotifyArtistIds = const [],
  }) async {
    final title = _normalize(release.title);
    // 記号だけのタイトルは正規化で空に潰れる。空同士を一致と見なすと
    // 手当たり次第に当たってしまうので、名前での照合は諦める（id 直結の
    // 2 本目はタイトルを見ないので、そちらには進む）。
    if (title.isNotEmpty) {
      for (final artistId in spotifyArtistIds) {
        final shelf = await _spotify.artistAlbums(artistId);
        final match = _pick(shelf, title);
        if (match != null) return match;
      }
    }

    for (final albumId in await _musicBrainz.spotifyAlbumIds(
      release.releaseGroupMbid,
    )) {
      final album = await _spotify.album(albumId);
      if (album != null) return album;
    }
    return null;
  }

  /// そのアーティストの棚からタイトルで 1 枚選ぶ。
  static SpotifyAlbumMatch? _pick(
    List<SpotifyAlbumMatch> shelf,
    String title,
  ) {
    for (final album in shelf) {
      if (_normalize(album.name) == title) return album;
    }
    // Deluxe / Remastered / "- Single" のようなエディション表記の付いた盤も
    // 同じリリースとして拾う。**ただの前方一致では許さない** — それだと
    // 「Best」が同じアーティストの「Best of 〜」を掴んでしまう。
    for (final album in shelf) {
      final name = _normalize(album.name);
      if (!name.startsWith(title)) continue;
      if (_edition.hasMatch(name.substring(title.length))) return album;
    }
    return null;
  }

  /// タイトルの後ろに付いても同じリリースと見なす語。
  /// 正規化後に当てるので、`- Single` は `single`、`(Deluxe Edition)` は
  /// `deluxeedition` になっている。年号はリマスター盤の `Remastered 2021`。
  static final _edition = RegExp(
    r'^(?:single|ep|deluxe|expanded|special|limited|complete|'
    r'remaster(?:ed)?|anniversary|edition|version|explicit|bonustracks?|'
    r'初回限定盤|完全生産限定盤|通常盤|限定盤|デラックス|リマスター|\d{4})+$',
  );

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9぀-鿿]'), '');
}
