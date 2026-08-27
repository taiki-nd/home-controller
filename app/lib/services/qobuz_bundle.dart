import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'qobuz_api.dart';

/// bundle.js から取れた候補。
@immutable
class QobuzBundleKeys {
  const QobuzBundleKeys({required this.appId, required this.secrets});

  final String appId;

  /// **どれが当たりかは叩いてみるまで分からない。**
  /// bundle.js にはタイムゾーンごとの秘密が複数入っていて、実際に
  /// `track/getFileUrl` が通るものだけが本物（`QobuzController` が総当りする）。
  final List<String> secrets;

  bool get isEmpty => appId.isEmpty || secrets.isEmpty;
}

/// Web プレイヤーの bundle.js から app_id / app_secret を取り直す口
/// （`docs/qobuz-wiim-integration.md` §3.2）。
///
/// **正規表現一発では取れない。** 秘密は seed・info・extras の 3 つに割られて
/// タイムゾーン名で紐付けられており、連結 → 末尾 44 文字を落とす →
/// base64 デコード、で初めて 1 本の文字列になる。ここが仕様書の
/// 「bundle.js から抽出」の実体で、いちばん壊れやすい工程。
///
/// 失効したときは設定画面から叩く。**自動では走らせない**——起動のたびに
/// qobuz.com を舐めに行く必要はないし、失敗したときに原因が分かりにくくなる。
class QobuzBundle {
  QobuzBundle._();

  static const loginUrl = 'https://play.qobuz.com/login';
  static const _origin = 'https://play.qobuz.com';

  /// `<script src="/resources/7.1.3-b011/bundle.js">` を拾う。
  static final _bundlePathPattern = RegExp(
    r'<script src="(/resources/[^"]+/bundle\.js)"',
  );

  /// `production:{api:{appId:"798273057",appSecret:"…"}}`。
  static final _appIdPattern = RegExp(
    r'production:\{api:\{appId:"(\d{9})",appSecret:"(\w{32})"',
  );

  /// `n.initialSeed("…",window.utimezone.berlin)`。
  static final _seedPattern = RegExp(
    r'[a-z]\.initialSeed\("([\w=]+)",window\.utimezone\.([a-z]+)\)',
  );

  /// 秘密の残り 2/3。タイムゾーン名で seed と紐付く。
  static RegExp _infoPattern(String timezone) =>
      RegExp('name:"\\w+/$timezone",info:"([\\w=]+)",extras:"([\\w=]+)"');

  /// 取りに行く。ネットワークが要る唯一の部分。
  static Future<QobuzBundleKeys> discover({Dio? dio}) async {
    final client =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
            responseType: ResponseType.plain,
          ),
        );
    try {
      final login = await client.get<String>(loginUrl);
      final path = _bundlePathPattern.firstMatch(login.data ?? '')?.group(1);
      if (path == null) {
        throw QobuzAppException('bundle.js の場所が分かりませんでした（Qobuz 側の作りが変わった可能性）');
      }
      final bundle = await client.get<String>('$_origin$path');
      final keys = extract(bundle.data ?? '');
      if (keys.isEmpty) {
        throw QobuzAppException('bundle.js から app_id / app_secret を取れませんでした');
      }
      return keys;
    } on DioException catch (e) {
      debugPrint('QobuzBundle.discover failed: ${e.type}');
      throw QobuzAppException('Qobuz の Web プレイヤーに接続できませんでした');
    } finally {
      if (dio == null) client.close(force: true);
    }
  }

  /// bundle.js の中身から鍵を組み立てる。**ここは純粋関数**——
  /// テスト（`test/qobuz_bundle_test.dart`）で固定の入力から検証する。
  static QobuzBundleKeys extract(String bundle) {
    final appId = _appIdPattern.firstMatch(bundle)?.group(1) ?? '';
    final secrets = <String>[];
    for (final seedMatch in _seedPattern.allMatches(bundle)) {
      final seed = seedMatch.group(1)!;
      final timezone = seedMatch.group(2)!;
      // seed 側は小文字（berlin）、info 側は先頭大文字（Europe/Berlin）。
      final capitalized =
          timezone[0].toUpperCase() + timezone.substring(1).toLowerCase();
      final info = _infoPattern(capitalized).firstMatch(bundle);
      if (info == null) continue;
      final joined = '$seed${info.group(1)}${info.group(2)}';
      // 末尾 44 文字は捨てる。ここを間違えるとデコードは通るのに
      // 署名だけ合わない、という一番分かりにくい壊れ方をする。
      if (joined.length <= 44) continue;
      final secret = _decode(joined.substring(0, joined.length - 44));
      if (secret != null && !secrets.contains(secret)) secrets.add(secret);
    }
    return QobuzBundleKeys(appId: appId, secrets: secrets);
  }

  static String? _decode(String value) {
    try {
      return utf8.decode(base64.decode(base64.normalize(value)));
    } catch (e) {
      // 別のタイムゾーンで拾えることがあるので、1 本転んでも続ける。
      debugPrint('QobuzBundle: secret の復号に失敗（読み飛ばす）');
      return null;
    }
  }
}
