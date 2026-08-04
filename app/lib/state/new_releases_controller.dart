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
      for (final artist in followed) {
        final mbid = mbidByUrl[artist.musicBrainzLookupUrl];
        if (mbid == null) {
          unresolved.add(artist.name);
        } else {
          resolved.add(mbid);
        }
      }
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
/// **MusicBrainz の MBID から Spotify の URI は直接引けない。**
/// Spotify は MBID を知らないので、アーティスト名 + タイトルの検索で当てるしか
/// なく、リマスター・地域盤・エディション違いの表記揺れで必ず取りこぼす。
/// リスト全体ではなく**押された行だけ**解決するのはこのコストのため。
class ReleaseResolver {
  const ReleaseResolver(this._spotify);

  final SpotifyApi _spotify;

  /// 見つからなければ null。
  Future<SpotifyAlbumMatch?> resolve(NewRelease release) async {
    final page = await _spotify.searchAlbums(
      '${release.artistName} ${release.title}',
    );
    if (page.isEmpty) return null;

    // 完全一致を優先し、無ければ先頭。Spotify 側の並びは関連度順。
    final wanted = _normalize(release.title);
    for (final album in page) {
      if (_normalize(album.name) == wanted) return album;
    }
    return page.first;
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9぀-鿿]'), '');
}
