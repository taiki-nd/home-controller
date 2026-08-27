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

  /// **本文が**この中に居る限りは自由に行き来させる。
  ///
  /// ログインには Qobuz 以外のホストも要る（reCAPTCHA の google.com /
  /// gstatic.com、SNS ログインなど）が、それらは iframe で動くので
  /// ここには並べない——フレームで見分ける（[allowNavigation]）。
  static const allowedHosts = ['qobuz.com', 'qobuz.net'];

  /// 進んでいい行き先か。**ここは 2 回壊しているので純粋関数にしてある。**
  ///
  /// 締め方を 2 段に分ける:
  ///
  /// 1. **スキームはフレームを問わず http(s) だけ。** `qobuz://` のような
  ///    カスタムスキームは、**副フレームから投げられても OS がアプリを
  ///    起こす**。「iframe だから安全」ではない——ここを開けたまま
  ///    reCAPTCHA を通そうとして、アプリに攫われる状態に戻していた
  /// 2. **ホストを見るのは本文だけ。** 副フレームまでホストで締めると
  ///    reCAPTCHA（google.com / gstatic.com）が読めず、ログイン画面が
  ///    「reCAPTCHA サービスに接続できません」で詰む
  static bool allowNavigation(String url, {required bool isMainFrame}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (!isMainFrame) return true;
    final host = uri.host.toLowerCase();
    return allowedHosts.any(
      (allowed) => host == allowed || host.endsWith('.$allowed'),
    );
  }

  static const loginUrl = QobuzBundle.loginUrl;

  /// ページに毎回差し込む。**何度流し込んでも二重に掛からない。**
  ///
  /// やることは 2 つ:
  ///
  /// - `fetch` / `XMLHttpRequest` の**ヘッダと URL の両方**を覗いて
  ///   `X-App-Id` と `X-User-Auth-Token` を拾う（Web プレイヤーは操作のたびに
  ///   API を叩くので、途中から掛けても次の 1 回で捕まる）。
  ///   **URL を見るのが要**——Qobuz は `app_id` をヘッダではなく
  ///   `?app_id=…` のクエリで送ることがあり、ヘッダだけ見ていると
  ///   トークンは取れるのに app_id だけ永遠に埋まらない
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
      // **app_id が揃うのを待たない。** トークンさえ取れていれば送る——
      // app_id は bundle.js 側にも書いてあるので Dart 側で補える。
      // 両方揃うまで黙っていると、app_id だけ拾えないページで
      // 永遠に何も起きない画面になる。
      if (B.token) {
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
    B.query = function (u) {
      // `?app_id=…&user_auth_token=…`。**ヘッダに出ない口がここにある。**
      if (!u) return;
      try {
        var text = String(u);
        var mark = text.indexOf('?');
        if (mark < 0) return;
        var parts = text.slice(mark + 1).split('&');
        for (var i = 0; i < parts.length; i++) {
          var pair = parts[i].split('=');
          if (pair.length < 2) continue;
          B.take(decodeURIComponent(pair[0]), decodeURIComponent(pair[1]));
        }
      } catch (e) {}
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
          B.query(typeof input === 'string' ? input : input && input.url);
        } catch (e) {}
        return fetchOriginal.apply(this, arguments);
      };
    }
    var openOriginal = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { B.query(url); } catch (e) {}
      return openOriginal.apply(this, arguments);
    };
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
      // **掛ける前に済んでいた通信も拾う。** SPA は起動直後に API を叩くので、
      // フックが間に合わないことがある。performance には URL が残っていて、
      // app_id はそこ（クエリ）にも書いてある。
      try {
        var entries = performance.getEntriesByType('resource');
        for (var e = 0; e < entries.length; e++) B.query(entries[e].name);
      } catch (e) {}
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
  // script タグで見つからないとき。**いま開いているページの HTML を先に見る**
  // ——ログイン後は /login を取り直しても中身が変わっていることがある。
  var inline = document.documentElement.innerHTML.match(
    /\/resources\/[^"']+\/bundle\.js/
  );
  if (inline) { grab(location.origin + inline[0]).catch(fail); return; }
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
