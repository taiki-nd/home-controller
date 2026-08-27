import 'dart:convert';

import 'package:crypto/crypto.dart';

/// `track/getFileUrl` の署名（`docs/qobuz-wiim-integration.md` §3.3）。
///
/// **ここが間違うと再生だけが一切できず、原因が分かりにくい。**
/// 401 でも 404 でもなく「署名が違う」という一言が返るだけなので、
/// 必ずユニットテスト（`test/qobuz_signature_test.dart`）で固定値と突き合わせる。
///
/// 作り方:
///
/// ```
/// md5(<object><method> + <キー昇順に key と value を連結> + <request_ts> + <app_secret>)
/// ```
///
/// `track/getFileUrl` なら `trackgetFileUrl` + `format_id27` + `intentstream`
/// + `track_id12345678` + `1700000000` + secret。
/// **区切り文字は入らない。** キーと値をそのまま繋ぐ。
class QobuzSignature {
  QobuzSignature._();

  /// 署名の対象に含めないパラメータ。
  ///
  /// `app_id` と `user_auth_token` はヘッダで送るもの、`request_ts` は末尾に
  /// 別枠で付くもの、`request_sig` は結果そのもの。
  static const _excluded = {
    'app_id',
    'user_auth_token',
    'request_ts',
    'request_sig',
  };

  /// [endpoint] は `track/getFileUrl` のようなパス。スラッシュは落として繋ぐ。
  static String create({
    required String endpoint,
    required Map<String, Object?> params,
    required int requestTs,
    required String appSecret,
  }) {
    final buffer = StringBuffer(endpoint.replaceAll('/', ''));
    final keys = params.keys.where((k) => !_excluded.contains(k)).toList()
      ..sort();
    for (final key in keys) {
      final value = params[key];
      if (value == null) continue;
      buffer
        ..write(key)
        ..write(value);
    }
    buffer
      ..write(requestTs)
      ..write(appSecret);
    return md5.convert(utf8.encode(buffer.toString())).toString();
  }

  /// ログインで送るパスワードのハッシュ。**平文は保存もログ出力もしない。**
  static String hashPassword(String password) =>
      md5.convert(utf8.encode(password)).toString();
}
