import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/qobuz_bundle.dart';
import 'package:spotify_remote/services/qobuz_web_login.dart';

/// アプリ内ブラウザからの取り込み（`docs/qobuz-wiim-integration.md` §3.2）。
///
/// **JS そのものは実機でしか動かない**ので、ここで押さえるのは
/// 「橋を渡ってきた値をどう読むか」と「削り込んでも鍵が組み立つか」の 2 点。
void main() {
  const tail = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
  const encoded = 'YWFhYWJiYmJjY2NjZGRkZGVlZWVmZmZmZ2dnZ2hoaGg=';
  const secret = 'aaaabbbbccccddddeeeeffffgggghhhh';

  /// 本物の bundle.js に近い形（前後にノイズを挟む）。
  String bundle({String timezone = 'berlin'}) {
    const payload = '$encoded$tail';
    final seed = payload.substring(0, 10);
    final info = payload.substring(10, 30);
    final extras = payload.substring(30);
    final capitalized = timezone[0].toUpperCase() + timezone.substring(1);
    return 'var a=1;'
        'production:{api:{appId:"798273057",appSecret:"0123456789abcdef0123456789abcdef"}}'
        ';function noise(){return 0}'
        'n.initialSeed("$seed",window.utimezone.$timezone)'
        ';var b=2;name:"Europe/$capitalized",info:"$info",extras:"$extras"'
        ';var c=3;';
  }

  group('QobuzBundle.reduce', () {
    test('削り込んでも extract の結果は変わらない', () {
      final full = bundle();
      final reduced = QobuzBundle.reduce(full);
      expect(reduced.length, lessThan(full.length));
      expect(QobuzBundle.extract(reduced).appId, '798273057');
      expect(QobuzBundle.extract(reduced).secrets, [secret]);
    });

    test('当たりが無ければ空になる（数 MB を橋に流さないため）', () {
      expect(QobuzBundle.reduce('var a=1;'), isEmpty);
      expect(QobuzBundle.extract('').isEmpty, isTrue);
    });
  });

  group('QobuzWebLogin', () {
    test('bundle 用のスクリプトには Dart 側と同じ正規表現が載る', () {
      final script = QobuzWebLogin.bundleScript;
      expect(script, isNot(contains('__PATTERNS__')));
      // JS の `new RegExp(...)` に渡すので、載るのは JSON エスケープ済みの形。
      expect(script, contains(jsonEncode(QobuzBundle.patterns)));
      expect(QobuzBundle.patterns, hasLength(3));
    });

    test('取り込みスクリプトは二重に掛からない目印を持つ', () {
      expect(QobuzWebLogin.captureScript, contains('__homeCtlQobuz'));
      expect(QobuzWebLogin.captureScript, contains(QobuzWebLogin.channelName));
    });

    test('ヘッダだけでなく URL のクエリも見る', () {
      // Qobuz は app_id を `?app_id=…` で送ることがあり、ヘッダだけ見ていると
      // トークンは取れるのに app_id が永遠に埋まらない。
      final script = QobuzWebLogin.captureScript;
      expect(script, contains('B.query'));
      expect(script, contains('XMLHttpRequest.prototype.open'));
      expect(script, contains('getEntriesByType'));
    });

    test('app_id が揃うのを待たずにトークンを渡す', () {
      // 待つと、app_id を拾えないページで永遠に何も起きない画面になる。
      expect(QobuzWebLogin.captureScript, contains('if (B.token) {'));
      expect(QobuzWebLogin.captureScript, isNot(contains('B.appId && B.token')));
    });
  });

  group('QobuzWebMessage', () {
    test('app_id の無い auth も読む（bundle.js 側で補う）', () {
      final message = QobuzWebMessage.parse(
        '{"type":"auth","token":"abcdefghijklmnopqrst"}',
      );
      expect(message!.isAuth, isTrue);
      expect(message.appId, isNull);
      expect(message.token, 'abcdefghijklmnopqrst');
    });

    test('auth を読む', () {
      final message = QobuzWebMessage.parse(
        '{"type":"auth","appId":"798273057","token":"abcdefghijklmnopqrst"}',
      );
      expect(message!.isAuth, isTrue);
      expect(message.appId, '798273057');
      expect(message.token, 'abcdefghijklmnopqrst');
    });

    test('bundle と error を見分ける', () {
      expect(
        QobuzWebMessage.parse('{"type":"bundle","bundle":"x"}')!.isBundle,
        isTrue,
      );
      expect(
        QobuzWebMessage.parse('{"type":"error","message":"だめ"}')!.isError,
        isTrue,
      );
    });

    test('読めない通は捨てる（ページ側が何を投げてくるか分からない）', () {
      expect(QobuzWebMessage.parse('こんにちは'), isNull);
      expect(QobuzWebMessage.parse('[]'), isNull);
      expect(QobuzWebMessage.parse('{"appId":"798273057"}'), isNull);
    });

    test('トークンは toString に出ない（ログ出力厳禁）', () {
      const result = QobuzWebLoginResult(
        appId: '798273057',
        token: 'ひみつ',
        secrets: [secret],
      );
      expect(result.toString(), isNot(contains('ひみつ')));
    });
  });
}
