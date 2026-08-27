import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/qobuz_models.dart';
import 'qobuz_credentials.dart';
import 'qobuz_signature.dart';

/// Qobuz とのやり取りが失敗した。文言はそのまま画面に出す前提で作る。
class QobuzException implements Exception {
  QobuzException(this.message);

  final String message;

  @override
  String toString() => 'QobuzException: $message';
}

/// トークンが拒否された。**通信断と必ず区別する。**
/// 叩き直しても直らないので、リトライを回さずにログイン画面へ戻す。
class QobuzAuthException extends QobuzException {
  QobuzAuthException(super.message);
}

/// app_id / app_secret のほうが死んでいる。
///
/// **トークン切れと混同しない**（§3）。ログインし直しても直らず、
/// bundle.js から取り直すしかない。ここを分けておかないと、
/// 「再ログインを促す → また同じエラー」の無限ループになる。
class QobuzAppException extends QobuzException {
  QobuzAppException(super.message);
}

/// Qobuz REST v0.2 のクライアント（`docs/qobuz-wiim-integration.md` §3）。
///
/// **WiiM 用の [Dio] とは必ず別インスタンスにする。** 向こうは自己署名証明書の
/// ために検証を切っており、それを Qobuz 側に持ち込んではいけない。
class QobuzApi {
  QobuzApi({this.config, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              // 4xx は例外にせず自分で読む。Qobuz は本文の message に
              // 「何が悪いか」を書いてくるので、そこを見ないと app_id 切れと
              // トークン切れを区別できない。
              validateStatus: (status) => status != null && status < 500,
            ),
          );

  static const baseUrl = 'https://www.qobuz.com/api.json/0.2';

  /// 一度に引く上限。Qobuz 側の上限も 500 前後。
  static const _pageLimit = 500;

  final Dio _dio;

  /// 差し替え可能にしてある（§6）。失効したら bundle.js から取り直して入れ替える。
  QobuzAppConfig? config;

  /// `X-User-Auth-Token`。**ログに出さない。**
  String? token;

  bool get hasToken => token != null && token!.isNotEmpty;

  // ── 認証 ────────────────────────────────────────────────────────────

  /// メールとパスワードでログインする。**パスワードは MD5 にして送る。**
  Future<QobuzUser> login({
    required String email,
    required String password,
  }) async {
    final json = await _request(
      'user/login',
      method: 'POST',
      params: {
        'email': email,
        'password': QobuzSignature.hashPassword(password),
      },
      // ログインだけはトークンを載せない（古いトークンが残っていると
      // 「別のユーザーで入り直す」ができなくなる）。
      withToken: false,
    );
    final token = json['user_auth_token'];
    final user = json['user'];
    if (token is! String || token.isEmpty || user is! Map) {
      throw QobuzAuthException('ログインに失敗しました');
    }
    final id = (user['id'] as num?)?.toInt();
    if (id == null) throw QobuzAuthException('ログインに失敗しました');
    final credential = user['credential'];
    return QobuzUser(
      id: id,
      token: token,
      displayName: user['display_name'] as String?,
      email: user['email'] as String?,
      subscription: credential is Map ? credential['label'] as String? : null,
    );
  }

  /// トークンがまだ通るかの確認。起動時に一度だけ叩く。
  Future<void> verifyToken() => _request('user/get', params: const {});

  /// いま載せているトークンの持ち主。
  ///
  /// **アプリ内ブラウザから来たトークンには user_id が付いてこない**
  /// （`QobuzWebLogin`）。自分のプレイリストの判定に user_id が要るので、
  /// ここで引き直す。応答は user を包む形と剥き出しの形の両方があるので、
  /// どちらでも読めるようにしておく。
  Future<QobuzUser> currentUser() async {
    final json = await _request('user/get', params: const {});
    final wrapped = json['user'];
    final user = wrapped is Map
        ? Map<String, dynamic>.from(wrapped)
        : json;
    final id = (user['id'] as num?)?.toInt();
    if (id == null) throw QobuzAuthException('Qobuz のアカウントを読めませんでした');
    final credential = user['credential'];
    return QobuzUser(
      id: id,
      token: token ?? '',
      displayName: user['display_name'] as String?,
      email: user['email'] as String?,
      subscription: credential is Map ? credential['label'] as String? : null,
    );
  }

  // ── ブラウズ ────────────────────────────────────────────────────────

  Future<List<QobuzPlaylist>> userPlaylists({int? ownerUserId}) async {
    final json = await _request(
      'playlist/getUserPlaylists',
      params: const {'limit': 100},
    );
    return _items(json['playlists'])
        .map((raw) => QobuzPlaylist.tryFrom(raw, ownerUserId: ownerUserId))
        .whereType<QobuzPlaylist>()
        .toList(growable: false);
  }

  /// プレイリストの中身。
  ///
  /// **`extra=tracks` を付けないと `playlist_track_id` が取れない**
  /// （§3 の落とし穴 1）。削除も並べ替えもこの ID でしかできない。
  Future<QobuzPlaylist> playlist(int playlistId, {int? ownerUserId}) async {
    final json = await _request(
      'playlist/get',
      params: {
        'playlist_id': playlistId,
        'extra': 'tracks',
        'limit': _pageLimit,
      },
    );
    final playlist = QobuzPlaylist.tryFrom(json, ownerUserId: ownerUserId);
    if (playlist == null) throw QobuzException('プレイリストを読めませんでした');
    return playlist;
  }

  Future<QobuzAlbum> album(String albumId) async {
    final json = await _request('album/get', params: {'album_id': albumId});
    final album = QobuzAlbum.tryFrom(json);
    if (album == null) throw QobuzException('アルバムを読めませんでした');
    return album;
  }

  /// トラック / アルバム / アーティストをまとめて引く。
  ///
  /// 3 本を並行で投げる。**1 本が転んでも残りは出す**——検索が全滅するより、
  /// 取れたぶんだけ出したほうが使える。
  Future<QobuzSearchResults> search(String query, {int limit = 30}) async {
    final params = {'query': query, 'limit': limit};
    final results = await Future.wait([
      _requestOrNull('track/search', params: params),
      _requestOrNull('album/search', params: params),
      _requestOrNull('artist/search', params: params),
    ]);
    return QobuzSearchResults(
      tracks: _items(
        results[0]?['tracks'],
      ).map(QobuzTrack.tryFrom).whereType<QobuzTrack>().toList(growable: false),
      albums: _items(
        results[1]?['albums'],
      ).map(QobuzAlbum.tryFrom).whereType<QobuzAlbum>().toList(growable: false),
      artists: _items(results[2]?['artists'])
          .map(QobuzArtist.tryFrom)
          .whereType<QobuzArtist>()
          .toList(growable: false),
    );
  }

  Future<QobuzFavorites> favorites({int limit = 100}) async {
    final json = await _request(
      'favorite/getUserFavorites',
      params: {'limit': limit},
    );
    return QobuzFavorites(
      tracks: _items(
        json['tracks'],
      ).map(QobuzTrack.tryFrom).whereType<QobuzTrack>().toList(growable: false),
      albums: _items(
        json['albums'],
      ).map(QobuzAlbum.tryFrom).whereType<QobuzAlbum>().toList(growable: false),
      artists: _items(json['artists'])
          .map(QobuzArtist.tryFrom)
          .whereType<QobuzArtist>()
          .toList(growable: false),
    );
  }

  /// アーティストのアルバム。検索から辿るため。
  Future<List<QobuzAlbum>> artistAlbums(int artistId, {int limit = 100}) async {
    final json = await _request(
      'artist/get',
      params: {'artist_id': artistId, 'extra': 'albums', 'limit': limit},
    );
    return _items(
      json['albums'],
    ).map(QobuzAlbum.tryFrom).whereType<QobuzAlbum>().toList(growable: false);
  }

  // ── プレイリスト編集 ────────────────────────────────────────────────

  Future<QobuzPlaylist> createPlaylist({
    required String name,
    String description = '',
    bool isPublic = false,
  }) async {
    final json = await _request(
      'playlist/create',
      method: 'POST',
      params: {
        'name': name,
        'description': description,
        'is_public': isPublic ? 'true' : 'false',
      },
    );
    final playlist = QobuzPlaylist.tryFrom(json);
    if (playlist == null) throw QobuzException('プレイリストを作れませんでした');
    return playlist;
  }

  /// トラックを足す。
  ///
  /// **カンマ区切りで渡した順序がそのまま保たれる**（§3 の落とし穴 2）。
  /// これが効くので、順序を作るのに並べ替え API は要らない。
  Future<void> addTracks(int playlistId, List<int> trackIds) async {
    if (trackIds.isEmpty) return;
    await _request(
      'playlist/addTracks',
      method: 'POST',
      params: {'playlist_id': playlistId, 'track_ids': trackIds.join(',')},
    );
  }

  /// 行を消す。**`track_id` ではなく `playlist_track_id`**（落とし穴 1）。
  ///
  /// 反映に遅延があるので、**直後の `playlist/get` の結果で位置を計算しない**
  /// （落とし穴 4）。
  Future<void> deleteTracks(int playlistId, List<int> playlistTrackIds) async {
    if (playlistTrackIds.isEmpty) return;
    await _request(
      'playlist/deleteTracks',
      method: 'POST',
      params: {
        'playlist_id': playlistId,
        'playlist_track_ids': playlistTrackIds.join(','),
      },
    );
  }

  /// 行を [index] 番目（0 始まり）へ動かす。
  ///
  /// **`insert_before` は 1 始まりのポジション**（落とし穴 3）。
  /// 0-based と誤解すると全体が 1 つずつずれる。`insert_before=0` は先頭に
  /// クランプされて 1 と区別が付かないので、ここで +1 して渡す。
  Future<void> moveTracks(
    int playlistId,
    List<int> playlistTrackIds,
    int index,
  ) async {
    if (playlistTrackIds.isEmpty) return;
    await _request(
      'playlist/updateTracksPosition',
      method: 'POST',
      params: {
        'playlist_id': playlistId,
        'playlist_track_ids': playlistTrackIds.join(','),
        'insert_before': index + 1,
      },
    );
  }

  // ── ストリーム ──────────────────────────────────────────────────────

  /// 署名付きの再生 URL を取る。**唯一署名が要るエンドポイント。**
  ///
  /// **再生直前に呼ぶこと。** 返る URL は 24 時間ほどで失効するので、
  /// キュー全曲ぶんを先に取ると後半が死ぬ（§3）。
  Future<QobuzFileUrl> fileUrl(
    int trackId, {
    QobuzFormat format = QobuzFormat.hires192,
    DateTime? now,
  }) async {
    final config = this.config;
    if (config == null || config.appSecret.isEmpty) {
      throw QobuzAppException('app_secret が設定されていません');
    }
    final ts = ((now ?? DateTime.now()).millisecondsSinceEpoch / 1000).floor();
    final params = <String, Object?>{
      'track_id': trackId,
      'format_id': format.id,
      'intent': 'stream',
    };
    final json = await _request(
      'track/getFileUrl',
      params: {
        ...params,
        'request_ts': ts,
        'request_sig': QobuzSignature.create(
          endpoint: 'track/getFileUrl',
          params: params,
          requestTs: ts,
          appSecret: config.appSecret,
        ),
      },
    );
    final file = QobuzFileUrl.tryFrom(json, trackId: trackId);
    if (file == null) {
      // restrictions は「この契約では鳴らせない」「地域外」など。
      final restrictions = json['restrictions'];
      final reason = restrictions is List && restrictions.isNotEmpty
          ? '（${restrictions.first is Map ? restrictions.first['code'] : restrictions.first}）'
          : '';
      throw QobuzException('この曲は再生できません$reason');
    }
    return file;
  }

  // ── 下回り ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _request(
    String endpoint, {
    String method = 'GET',
    required Map<String, Object?> params,
    bool withToken = true,
  }) async {
    final config = this.config;
    if (config == null || config.appId.isEmpty) {
      throw QobuzAppException('app_id が設定されていません');
    }
    final headers = <String, String>{'X-App-Id': config.appId};
    final token = this.token;
    if (withToken && token != null && token.isNotEmpty) {
      headers['X-User-Auth-Token'] = token;
    }
    final Response<Object?> response;
    try {
      response = await _dio.request<Object?>(
        '/$endpoint',
        queryParameters: params,
        options: Options(method: method, headers: headers),
      );
    } on DioException catch (e) {
      // ここに来るのは接続断・タイムアウト・5xx。**認証の失敗ではない。**
      debugPrint('QobuzApi $endpoint failed: ${e.type}');
      throw QobuzException('Qobuz に接続できませんでした');
    }
    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status >= 200 && status < 300) {
      if (data is Map) return Map<String, dynamic>.from(data);
      // 204 など本文なし。成功として空を返す。
      return const {};
    }
    throw _errorFor(status, data, endpoint);
  }

  /// 転んだら null を返す版。検索の並行呼び出し用。
  Future<Map<String, dynamic>?> _requestOrNull(
    String endpoint, {
    required Map<String, Object?> params,
  }) async {
    try {
      return await _request(endpoint, params: params);
    } on QobuzAuthException {
      // 認証だけは握りつぶさない。ログイン画面へ倒す必要がある。
      rethrow;
    } on QobuzException catch (e) {
      debugPrint('QobuzApi $endpoint skipped: ${e.message}');
      return null;
    }
  }

  /// 応答本文から「何が死んでいるか」を決める。
  ///
  /// **401 だけを app_id 切れの目印にしない**（§3）。Qobuz は無効な app_id に
  /// 400 を返すことがあり、コードだけではトークン切れと区別が付かない。
  /// message の中身まで見る。
  QobuzException _errorFor(int status, Object? data, String endpoint) {
    final message = data is Map ? data['message']?.toString() ?? '' : '';
    final lower = message.toLowerCase();
    if (lower.contains('app_id') ||
        lower.contains('application') ||
        lower.contains('invalid signature') ||
        lower.contains('request_sig')) {
      return QobuzAppException('app_id / app_secret が拒否されました。取り直してください');
    }
    if (status == 401 || lower.contains('auth') || lower.contains('token')) {
      return QobuzAuthException('Qobuz のログインが切れました');
    }
    if (status == 400 && endpoint == 'user/login') {
      return QobuzAuthException('メールアドレスかパスワードが違います');
    }
    return QobuzException(
      message.isEmpty ? 'Qobuz がエラーを返しました（$status）' : message,
    );
  }

  /// `{items: [...]}` から中身を取り出す。
  static List<Object?> _items(Object? raw) {
    if (raw is Map) {
      final items = raw['items'];
      if (items is List) return items;
    }
    if (raw is List) return raw;
    return const [];
  }

  void close() => _dio.close(force: true);
}
