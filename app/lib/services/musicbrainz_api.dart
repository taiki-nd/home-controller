import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/release_models.dart';

/// MusicBrainz が返した失敗。呼び出し側は新譜が出ないだけで済ませる。
class MusicBrainzException implements Exception {
  MusicBrainzException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'MusicBrainzException($statusCode): $message';
}

/// MusicBrainz Web Service v2 クライアント（設計メモ §14）。
///
/// **負荷をここに逃がすのが目的。** Spotify 側でフォロー中アーティストを
/// 1人ずつ舐めると、429 中は [SpotifyApi] が再生操作まで含めた全リクエストを
/// 弾くため、パーティ中にコントローラごと止まる。MusicBrainz なら最悪でも
/// 新譜が出ないだけで済む。
class MusicBrainzApi {
  MusicBrainzApi({
    Dio? dio,
    String userAgent = defaultUserAgent,
    Duration minInterval = _defaultInterval,
  }) : _userAgent = userAgent,
       _minInterval = minInterval,
       _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://musicbrainz.org/ws/2',
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              validateStatus: (_) => true,
            ),
          );

  /// **User-Agent は必須。付けないと 403 が返る**（実測）。
  /// MusicBrainz は連絡先入りの文字列を求めている。
  static const defaultUserAgent =
      'HomeController/1.0 ( https://github.com/taiki-nd/home-controller )';

  /// 1クエリに載せる Spotify URL の数。
  ///
  /// URL 1本が約60字なので、これ以上増やすとクエリ文字列が長くなりすぎる。
  /// 実測では 8,935字で 414 URI Too Long。
  static const _urlBatch = 50;

  /// 1クエリに載せる arid（アーティストMBID）の数。
  ///
  /// **実測: 100 は 200 OK（URL 4,535字）、200 は 414 URI Too Long。**
  /// ここが N+1 を潰している要。
  static const _aridBatch = 100;

  /// MusicBrainz は平均 1 req/sec を超えないよう求めている。
  /// テストからは短くできるが、**本番でここを縮めてはいけない**（503 になる）。
  static const _defaultInterval = Duration(milliseconds: 1100);

  /// 新譜として扱わない二次タイプ。**Remix はここに入れない**（新譜扱い）。
  ///
  /// 複数語のものは引用符で括る必要がある（`"Audio drama"` 等）。
  static const _excludedSecondaryTypes =
      'Compilation OR Live OR Soundtrack OR Interview OR Audiobook'
      ' OR Spokenword OR "Audio drama" OR "DJ-mix" OR "Mixtape/Street"'
      ' OR Demo OR "Field recording"';

  /// 検索の 1 ページ上限。
  static const _pageLimit = 100;

  /// 暴走したときの保険。フォロー数が多くてもこの枚数で打ち切る。
  static const _maxPages = 10;

  final Dio _dio;
  final String _userAgent;
  final Duration _minInterval;

  DateTime? _lastRequestAt;

  /// Spotify のアーティストURL → MusicBrainz の artist MBID。
  ///
  /// MusicBrainz はアーティストに Spotify の URL を関連として持っているので、
  /// **アーティスト名での名寄せが要らない。**
  ///
  /// **ただし関連はボランティア入力なので全員には付いていない。**
  /// 引けなかったものは戻り値に現れない（欠落は呼び出し側が数える）。
  Future<Map<String, String>> artistMbidsBySpotifyUrl(
    List<String> spotifyUrls,
  ) async {
    final result = <String, String>{};
    for (var i = 0; i < spotifyUrls.length; i += _urlBatch) {
      final batch = spotifyUrls.skip(i).take(_urlBatch).toList();
      final query = 'url:(${batch.map((u) => '"$u"').join(' OR ')})';
      final data = await _get('/url', {
        'query': query,
        'limit': _pageLimit,
        'fmt': 'json',
      });

      for (final entry
          in (data['urls'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()) {
        final resource = entry['resource'];
        if (resource is! String) continue;
        final mbid = _firstArtistMbid(entry);
        if (mbid != null) result[resource] = mbid;
      }
    }
    return result;
  }

  /// アーティストMBIDの集合に対して、期間内のリリース（release-group）を引く。
  ///
  /// [from] より前・[to] より後は返らない。[to] を未来に置けば**未発売のリリースも
  /// 取れる**（Spotify では原理的に不可能な部分）。
  Future<List<NewRelease>> releaseGroups({
    required List<String> artistMbids,
    required DateTime from,
    required DateTime to,
  }) async {
    if (artistMbids.isEmpty) return const [];
    final releases = <String, NewRelease>{};

    for (var i = 0; i < artistMbids.length; i += _aridBatch) {
      final batch = artistMbids.skip(i).take(_aridBatch).toList();
      // シングルとリミックスは新譜として拾う。落とすのは「新しく出た曲では
      // ないもの」だけ——ベスト盤・ライブ盤・サントラなど。
      //
      // **`-secondarytype:*` で二次タイプを一律に弾いてはいけない。**
      // それだと Remix まで落ちる。除外は種類を並べて名指しする。
      final query =
          'arid:(${batch.join(' OR ')})'
          ' AND firstreleasedate:[${_day(from)} TO ${_day(to)}]'
          ' AND primarytype:(Album OR EP OR Single)'
          ' AND -secondarytype:($_excludedSecondaryTypes)';

      for (var page = 0; page < _maxPages; page++) {
        final data = await _get('/release-group', {
          'query': query,
          'limit': _pageLimit,
          'offset': page * _pageLimit,
          'fmt': 'json',
        });
        final items = (data['release-groups'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(NewRelease.fromReleaseGroupJson)
            .whereType<NewRelease>();
        for (final release in items) {
          // 同じ release-group が別バッチで重複して返ることがある。
          releases[release.releaseGroupMbid] = release;
        }

        final count = (data['count'] as num?)?.toInt() ?? 0;
        if ((page + 1) * _pageLimit >= count) break;
      }
    }
    return releases.values.toList();
  }

  /// release-group にぶら下がるリリースの配信リンクから、Spotify のアルバム ID
  /// を拾う。
  ///
  /// **名寄せが要らない唯一の経路。** アーティストの Spotify URL 関連
  /// （[artistMbidsBySpotifyUrl]）と同じ仕組みが、リリース側にも付いている。
  ///
  /// ただし関連はボランティア入力なので、付いていない盤のほうがむしろ多い。
  /// 出てきた ID も**版が違うことがある**（国別盤・Deluxe など、同じ
  /// release-group の別リリースに付いた関連まで拾う）ので、呼び出し側は
  /// これを最後の手段として扱うこと。
  Future<List<String>> spotifyAlbumIds(String releaseGroupMbid) async {
    if (releaseGroupMbid.isEmpty) return const [];
    final data = await _get('/release', {
      'release-group': releaseGroupMbid,
      'inc': 'url-rels',
      'limit': _releaseBatch,
      'fmt': 'json',
    });

    final ids = <String>{};
    for (final release
        in (data['releases'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()) {
      for (final relation
          in (release['relations'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()) {
        final url = relation['url'];
        final resource = url is Map ? url['resource'] : null;
        if (resource is! String) continue;
        final match = _spotifyAlbumUrl.firstMatch(resource);
        if (match != null) ids.add(match.group(1)!);
      }
    }
    return ids.toList();
  }

  /// 1 つの release-group から見るリリースの数。版違いを全部舐める必要は無い。
  static const _releaseBatch = 25;

  /// `https://open.spotify.com/album/xxxx`。国別の `intl-ja` が挟まることがある。
  static final _spotifyAlbumUrl = RegExp(
    r'open\.spotify\.com/(?:intl-[a-z-]+/)?album/([A-Za-z0-9]+)',
  );

  /// url 検索の応答からアーティストMBIDを1つ取り出す。
  /// 応答の形が `relations` 直下だったり `relation-list` 経由だったりする。
  static String? _firstArtistMbid(Map<String, dynamic> entry) {
    Iterable<Map<String, dynamic>> relationsOf(dynamic node) {
      if (node is List) return node.whereType<Map<String, dynamic>>();
      return const [];
    }

    final direct = relationsOf(entry['relations']);
    final nested = relationsOf(
      entry['relation-list'],
    ).expand((group) => relationsOf(group['relations']));

    for (final relation in [...direct, ...nested]) {
      final artist = relation['artist'];
      if (artist is Map<String, dynamic> && artist['id'] is String) {
        return artist['id'] as String;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query,
  ) async {
    await _throttle();

    late final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        // User-Agent が無いと 403。ここを消してはいけない。
        options: Options(headers: {'User-Agent': _userAgent}),
      );
    } on DioException catch (e) {
      throw MusicBrainzException('通信に失敗しました: ${e.message ?? e.type.name}');
    }

    final status = response.statusCode ?? 0;
    if (status == 503) {
      // MusicBrainz は過負荷時に 503 を返す。呼び出し側で再試行させる。
      throw MusicBrainzException('MusicBrainz が混雑しています', statusCode: 503);
    }
    if (status == 414) {
      throw MusicBrainzException('問い合わせが長すぎました', statusCode: 414);
    }
    if (status < 200 || status >= 300) {
      throw MusicBrainzException(
        'MusicBrainz がエラーを返しました ($status)',
        statusCode: status,
      );
    }

    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    throw MusicBrainzException('応答を解釈できませんでした');
  }

  /// 平均 1 req/sec を守る。連続で投げると 503 を返されるようになる。
  Future<void> _throttle() async {
    final last = _lastRequestAt;
    if (last != null) {
      final wait = _minInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequestAt = DateTime.now();
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// デバッグ用。カバー率をログに出す。
void debugLogCoverage(MbCoverage coverage) {
  debugPrint(
    'MusicBrainz カバー率: ${coverage.resolved}/${coverage.followed} '
    '(${(coverage.ratio * 100).toStringAsFixed(1)}%)',
  );
}
