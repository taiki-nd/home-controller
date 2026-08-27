import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/qobuz_signature.dart';

/// 署名は**固定値と突き合わせる**（`docs/qobuz-wiim-integration.md` §8）。
/// 実装を書き直しても、ここが通れば再生できることが分かる。
///
/// 期待値は手計算ではなく `printf '%s' '<連結後の文字列>' | md5` で作った。
/// 連結後の文字列そのものも各テストのコメントに残してある。
void main() {
  const secret = 'abcdef0123456789abcdef0123456789';

  test('getFileUrl の署名が既知の MD5 と一致する', () {
    // trackgetFileUrlformat_id27intentstreamtrack_id123456781700000000<secret>
    expect(
      QobuzSignature.create(
        endpoint: 'track/getFileUrl',
        params: const {
          'track_id': 12345678,
          'format_id': 27,
          'intent': 'stream',
        },
        requestTs: 1700000000,
        appSecret: secret,
      ),
      '2778929834a2e2269741273cec621403',
    );
  });

  test('パラメータの並び順は署名に影響しない（キー昇順で連結する）', () {
    // trackgetFileUrlformat_id6intentstreamtrack_id5550<secret>
    const expected = '7693d107f3f1212444587d1d1489b781';
    for (final params in const [
      {'track_id': 555, 'format_id': 6, 'intent': 'stream'},
      {'intent': 'stream', 'track_id': 555, 'format_id': 6},
      {'format_id': 6, 'track_id': 555, 'intent': 'stream'},
    ]) {
      expect(
        QobuzSignature.create(
          endpoint: 'track/getFileUrl',
          params: params,
          requestTs: 0,
          appSecret: secret,
        ),
        expected,
      );
    }
  });

  test('app_id / user_auth_token / request_ts は署名に混ぜない', () {
    String sign(Map<String, Object?> params) => QobuzSignature.create(
      endpoint: 'track/getFileUrl',
      params: params,
      requestTs: 1700000000,
      appSecret: secret,
    );
    expect(
      sign(const {
        'track_id': 12345678,
        'format_id': 27,
        'intent': 'stream',
        'app_id': '798273057',
        'user_auth_token': 'xxx',
        'request_ts': 1,
        'request_sig': 'yyy',
      }),
      '2778929834a2e2269741273cec621403',
    );
  });

  test('null のパラメータは無かったものとして扱う', () {
    expect(
      QobuzSignature.create(
        endpoint: 'track/getFileUrl',
        params: const {
          'track_id': 12345678,
          'format_id': 27,
          'intent': 'stream',
          'sector': null,
        },
        requestTs: 1700000000,
        appSecret: secret,
      ),
      '2778929834a2e2269741273cec621403',
    );
  });

  test('パスワードは MD5 で送る（平文を投げない）', () {
    // 既知値。`printf '%s' 'password' | md5`
    expect(
      QobuzSignature.hashPassword('password'),
      '5f4dcc3b5aa765d61d8327deb882cf99',
    );
  });
}
