import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/qobuz_bundle.dart';

/// bundle.js からの抽出は**ネットワークを使わない純粋関数**として切ってある
/// ので、ここで固定の入力から検証できる（`docs/qobuz-wiim-integration.md` §8）。
///
/// 期待値の作り方:
///   base64("aaaabbbbccccddddeeeeffffgggghhhh") = 44 文字
///   → その後ろにダミーを 44 文字足したものを seed / info / extras に割る
///   → 実装は末尾 44 文字を落として base64 デコードするので元の秘密に戻る
void main() {
  // 44 文字のダミー。実装が末尾から落とす分。
  const tail = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
  // base64("aaaabbbbccccddddeeeeffffgggghhhh")
  const encoded = 'YWFhYWJiYmJjY2NjZGRkZGVlZWVmZmZmZ2dnZ2hoaGg=';
  const secret = 'aaaabbbbccccddddeeeeffffgggghhhh';

  String bundleWith({required String timezone, required String payload}) {
    final seed = payload.substring(0, 10);
    final info = payload.substring(10, 30);
    final extras = payload.substring(30);
    final capitalized = timezone[0].toUpperCase() + timezone.substring(1);
    return 'x.initialSeed("$seed",window.utimezone.$timezone)'
        '...name:"Europe/$capitalized",info:"$info",extras:"$extras"...';
  }

  test('app_id を拾う', () {
    const bundle =
        'production:{api:{appId:"798273057",appSecret:"0123456789abcdef0123456789abcdef"}}';
    expect(QobuzBundle.extract(bundle).appId, '798273057');
  });

  test('seed + info + extras から秘密を組み立てる', () {
    final bundle = bundleWith(timezone: 'berlin', payload: '$encoded$tail');
    expect(QobuzBundle.extract(bundle).secrets, [secret]);
  });

  test('タイムゾーンが複数あれば候補も複数返る（当たりは叩くまで分からない）', () {
    final bundle =
        '${bundleWith(timezone: 'berlin', payload: '$encoded$tail')}'
        '${bundleWith(timezone: 'london', payload: '$encoded$tail')}';
    // 同じ値になる作りのテスト素材なので重複は畳まれ、1 本だけ残る。
    expect(QobuzBundle.extract(bundle).secrets, [secret]);
  });

  test('info が見つからない seed は読み飛ばす（落とさない）', () {
    const bundle = 'x.initialSeed("abcdef",window.utimezone.berlin)';
    expect(QobuzBundle.extract(bundle).secrets, isEmpty);
    expect(QobuzBundle.extract(bundle).isEmpty, isTrue);
  });

  test('44 文字以下の連結は捨てる（切り出すと空になる）', () {
    final short = 'A' * 40;
    final bundle =
        'x.initialSeed("${short.substring(0, 10)}",window.utimezone.berlin)'
        'name:"Europe/Berlin",info:"${short.substring(10, 30)}",extras:"${short.substring(30)}"';
    expect(QobuzBundle.extract(bundle).secrets, isEmpty);
  });
}
