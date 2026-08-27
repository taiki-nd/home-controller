import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'qobuz_bundle.dart';

/// アプリ内ブラウザで Qobuz にログインして持ち帰るもの
/// （`docs/qobuz-wiim-integration.md` §3.2）。
@immutable
class QobuzWebLoginResult {
  const QobuzWebLoginResult({
    required this.appId,
    required this.token,
    this.secrets = const [],
  });

  /// Web プレイヤーが実際に使っている `X-App-Id`。
  final String appId;

  /// `X-User-Auth-Token`。**ログ出力厳禁。**
  final String token;

  /// bundle.js から組み立てた app_secret の候補。
  /// **どれが当たりかは叩くまで分からない**（`QobuzBundleKeys` と同じ）。
  final List<String> secrets;

  @override
  String toString() =>
      'QobuzWebLoginResult(appId: $appId, secrets: ${secrets.length}, token: ****)';
}

/// ブラウザ側から橋を渡って届く 1 通。
@immutable
class QobuzWebMessage {
  const QobuzWebMessage({
    required this.type,
    this.appId,
    this.token,
    this.bundle,
    this.message,
  });

  /// `auth` / `bundle` / `error`。
  final String type;
  final String? appId;
  final String? token;

  /// [QobuzBundle.reduce] 済みの bundle.js。
  final String? bundle;
  final String? message;

  bool get isAuth => type == 'auth';
  bool get isBundle => type == 'bundle';
  bool get isError => type == 'error';

  /// 読めない通は捨てる（ページ側の JS が何を投げてくるか分からないため）。
  static QobuzWebMessage? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final type = decoded['type'];
      if (type is! String) return null;
      return QobuzWebMessage(
        type: type,
        appId: decoded['appId'] as String?,
        token: decoded['token'] as String?,
        bundle: decoded['bundle'] as String?,
        message: decoded['message'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// アプリ内ブラウザから鍵とトークンを取る仕掛け（`§3.2`）。
///
/// **なぜ必要か。** `QobuzBundle.discover` は play.qobuz.com を素の HTTP
/// クライアントで舐めるだけなので、Qobuz 側がボット避けを挟むと何も取れない。
/// 本物のブラウザで本人がログインすれば、鍵もトークンも Web プレイヤー自身が
/// 用意してくれる——それを横から受け取る、というのがこの経路。
///
/// **パスワードは見ない。** 拾うのは
///
/// 1. `X-App-Id` / `X-User-Auth-Token`（[captureScript]）
/// 2. bundle.js の秘密の素（[bundleScript]）
///
/// の 2 つだけで、どちらもログイン後の Web プレイヤーが自分で持っている値。
class QobuzWebLogin {
  QobuzWebLogin._();

  /// `window.QobuzBridge.postMessage` の名前。
  static const channelName = 'QobuzBridge';

  static const loginUrl = QobuzBundle.loginUrl;

  /// ページに毎回差し込む。**何度流し込んでも二重に掛からない。**
  ///
  /// やることは 2 つ:
  ///
  /// - `fetch` / `XMLHttpRequest` のヘッダを覗いて `X-App-Id` と
  ///   `X-User-Auth-Token` を拾う（Web プレイヤーは操作のたびに API を叩くので、
  ///   途中から掛けても次の 1 回で捕まる）
  /// - localStorage / sessionStorage を舐めて同じ 2 つを探す
  ///   （**キー名を決め打ちしない**——Qobuz 側の都合で変わるので、
  ///   入れ子の JSON まで降りて名前で拾う）
  static String get captureScript => _captureScript;

  /// bundle.js を**ページ側で**読み、[QobuzBundle.patterns] に当たった箇所だけを
  /// 送り返す。数 MB を橋に流さないための削り込み（[QobuzBundle.reduce] と同じ）。
  static String get bundleScript => _bundleScript.replaceFirst(
    '__PATTERNS__',
    jsonEncode(QobuzBundle.patterns),
  );
}

const _captureScript = r'''
(function () {
  var B = window.__homeCtlQobuz;
  if (!B) {
    B = window.__homeCtlQobuz = { appId: null, token: null };
    B.post = function () {
      if (B.appId && B.token) {
        QobuzBridge.postMessage(
          JSON.stringify({ type: 'auth', appId: B.appId, token: B.token })
        );
      }
    };
    B.take = function (key, value) {
      if (!key || typeof value !== 'string' || !value) return;
      var k = String(key).toLowerCase().replace(/[^a-z]/g, '');
      if (k === 'xappid' || k === 'appid') {
        if (!/^[0-9]{6,12}$/.test(value)) return;
        B.appId = value;
      } else if (k === 'xuserauthtoken' || k === 'userauthtoken') {
        if (value.length < 16) return;
        B.token = value;
      } else {
        return;
      }
      B.post();
    };
    B.headers = function (h) {
      if (!h) return;
      try {
        if (typeof h.forEach === 'function') {
          h.forEach(function (v, k) { B.take(k, v); });
        } else if (Object.prototype.toString.call(h) === '[object Array]') {
          for (var i = 0; i < h.length; i++) B.take(h[i][0], h[i][1]);
        } else {
          var keys = Object.keys(h);
          for (var j = 0; j < keys.length; j++) B.take(keys[j], h[keys[j]]);
        }
      } catch (e) {}
    };
    var fetchOriginal = window.fetch;
    if (fetchOriginal) {
      window.fetch = function (input, init) {
        try {
          if (init) B.headers(init.headers);
          if (input && input.headers) B.headers(input.headers);
        } catch (e) {}
        return fetchOriginal.apply(this, arguments);
      };
    }
    var setHeaderOriginal = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function (key, value) {
      try { B.take(key, value); } catch (e) {}
      return setHeaderOriginal.apply(this, arguments);
    };
    B.walk = function (value, depth) {
      if (depth > 4 || value === null || value === undefined) return;
      if (typeof value === 'string') {
        var head = value.charAt(0);
        if (head !== '{' && head !== '[') return;
        try { B.walk(JSON.parse(value), depth + 1); } catch (e) {}
        return;
      }
      if (typeof value !== 'object') return;
      var keys = Object.keys(value);
      for (var i = 0; i < keys.length; i++) {
        B.take(keys[i], value[keys[i]]);
        B.walk(value[keys[i]], depth + 1);
      }
    };
    B.scan = function () {
      var stores = [];
      try { stores.push(window.localStorage); } catch (e) {}
      try { stores.push(window.sessionStorage); } catch (e) {}
      for (var s = 0; s < stores.length; s++) {
        var store = stores[s];
        if (!store) continue;
        for (var i = 0; i < store.length; i++) {
          var key = store.key(i);
          var value = store.getItem(key);
          B.take(key, value);
          B.walk(value, 0);
        }
      }
      B.post();
    };
  }
  B.scan();
})();
''';

const _bundleScript = r'''
(function () {
  var patterns = __PATTERNS__;
  function fail(e) {
    QobuzBridge.postMessage(
      JSON.stringify({
        type: 'error',
        message: String(e && e.message ? e.message : e)
      })
    );
  }
  function reduce(text) {
    var out = [];
    for (var i = 0; i < patterns.length; i++) {
      var found = text.match(new RegExp(patterns[i], 'g'));
      if (found) out.push(found.join('\n'));
    }
    return out.join('\n');
  }
  function grab(url) {
    return fetch(url, { credentials: 'include' })
      .then(function (r) { return r.text(); })
      .then(function (text) {
        QobuzBridge.postMessage(
          JSON.stringify({ type: 'bundle', bundle: reduce(text) })
        );
      });
  }
  var src = null;
  var scripts = document.getElementsByTagName('script');
  for (var i = 0; i < scripts.length; i++) {
    if (scripts[i].src && scripts[i].src.indexOf('bundle.js') >= 0) {
      src = scripts[i].src;
      break;
    }
  }
  if (src) { grab(src).catch(fail); return; }
  fetch('/login', { credentials: 'include' })
    .then(function (r) { return r.text(); })
    .then(function (html) {
      var m = html.match(/\/resources\/[^"']+\/bundle\.js/);
      if (!m) throw new Error('bundle.js の場所が分かりませんでした');
      return grab(location.origin + m[0]);
    })
    .catch(fail);
})();
''';
