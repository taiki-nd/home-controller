import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/qobuz_bundle.dart';
import '../../services/qobuz_web_login.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';

/// アプリ内ブラウザで Qobuz にログインし、鍵とトークンを持ち帰る画面
/// （`docs/qobuz-wiim-integration.md` §3.2）。
///
/// **本人がいつもどおりログインするだけ。** メールもパスワードもこのアプリは
/// 見ない（見る必要がない）。ログイン後の Web プレイヤーが自分で使っている
/// `X-App-Id` / `X-User-Auth-Token` と、bundle.js の秘密の素だけを受け取る。
///
/// 素の HTTP で play.qobuz.com を舐める `QobuzBundle.discover` は、Qobuz 側が
/// ボット避けを挟むと無言で空振りする。**本物のブラウザなら詰まらない**——
/// この経路を足したのはそれが理由。
class QobuzWebLoginScreen extends StatefulWidget {
  const QobuzWebLoginScreen({super.key});

  /// 開いて結果を待つ。取り込めなければ null。
  static Future<QobuzWebLoginResult?> open(BuildContext context) {
    return Navigator.of(context).push<QobuzWebLoginResult>(
      MaterialPageRoute<QobuzWebLoginResult>(
        builder: (context) => const QobuzWebLoginScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<QobuzWebLoginScreen> createState() => _QobuzWebLoginScreenState();
}

class _QobuzWebLoginScreenState extends State<QobuzWebLoginScreen> {
  /// ログイン後もページを見張る間隔。
  ///
  /// **1 回差し込んで終わりにしない。** 遷移のたびにフックは消えるし、
  /// localStorage に書かれるのはログイン処理が終わったあとなので、
  /// 定期的に舐め直すのがいちばん確実。
  static const _pollInterval = Duration(seconds: 2);

  /// アプリへ攫われないための UA。
  ///
  /// **既定の WKWebView は iPhone の Safari を名乗る。** すると
  /// play.qobuz.com は「アプリで開く」バナーと Universal Link を出してきて、
  /// ログインの途中で Qobuz のネイティブアプリに持っていかれる。
  /// デスクトップを名乗れば誘導ごと消え、ついでに bundle.js が確実に載る
  /// フル版の Web プレイヤーが返ってくる（鍵の取り込みはこれに乗っている）。
  static const _desktopUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15';

  WebViewController? _web;
  Timer? _poll;

  /// 自分で読み直すと決めた 1 件（[_open] 参照）。
  ///
  /// **自分の `loadRequest` も `onNavigationRequest` に返ってくる**ので、
  /// これが無いと止めては開き直すのを永遠に繰り返す。
  String? _passthrough;

  String? _appId;
  String? _token;
  bool _harvesting = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  void _setUp() {
    if (kIsWeb) {
      // web ビルド（`make app-web` / `app-mock`）には WebView が無い。
      _error = 'アプリ内ブラウザは iOS / Android のアプリでだけ使えます';
      return;
    }
    try {
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          QobuzWebLogin.channelName,
          onMessageReceived: (message) => _onMessage(message.message),
        )
        ..setUserAgent(_desktopUserAgent)
        ..setNavigationDelegate(
          NavigationDelegate(
            // **Qobuz の外へは出さない。** ここが無いと、ログインの途中で
            // カスタムスキーム（qobuz://）が発火してネイティブアプリに
            // 飛ばされ、この画面は空のまま取り残される。
            // 締め方は `QobuzWebLogin.allowNavigation` を参照（スキームは
            // フレームを問わず、ホストは本文だけ）。
            onNavigationRequest: (request) {
              // 自分で開き直した分。ここは素通しでいい。
              if (request.url == _passthrough) {
                _passthrough = null;
                return NavigationDecision.navigate;
              }
              if (QobuzWebLogin.allowNavigation(
                request.url,
                isMainFrame: request.isMainFrame,
              )) {
                // **本文の遷移は、通す代わりに自分で開き直す。**
                //
                // ここを素直に navigate すると、iOS が「利用者が踏んだ
                // リンク」と見なして Universal Link の判定に掛け、
                // qobuz.com が Qobuz アプリの関連ドメインに入っているため
                // ネイティブアプリに渡してしまう（ログイン直後の遷移で
                // これが起きる）。**プログラムからの読み込みは渡らない**
                // ので、いったん止めて同じ URL を自分で開く。
                //
                // 本文の POST は捨てることになるが、Qobuz のログインは
                // XHR で飛ぶ（だからトークンを横取りできている）ので、
                // ここを通るのは実質 GET だけ。
                if (request.isMainFrame) return _open(request.url);
                return NavigationDecision.navigate;
              }
              // **何を止めたかは残す。** ログインに要るものを巻き添えに
              // していても、黙って落とすと画面が固まったようにしか見えない。
              debugPrint(
                'QobuzWebLoginScreen blocked '
                '(main: ${request.isMainFrame}): '
                '${Uri.tryParse(request.url)?.scheme}://'
                '${Uri.tryParse(request.url)?.host}',
              );
              return NavigationDecision.prevent;
            },
            // 差し込みは「開いた直後」と「読み終わり」の両方でやる。
            // 片方だけだと、掛ける前に API を叩き終わっているページがある。
            onPageStarted: (_) => _inject(QobuzWebLogin.captureScript),
            onPageFinished: (_) => _inject(QobuzWebLogin.captureScript),
            onWebResourceError: (error) {
              // ページ内の画像 1 枚の失敗でも来る。**本文の失敗だけ出す。**
              if (error.isForMainFrame != true) return;
              if (!mounted) return;
              setState(() => _error = 'ページを開けませんでした（${error.description}）');
            },
          ),
        )
        ..loadRequest(Uri.parse(QobuzWebLogin.loginUrl));
      _poll = Timer.periodic(_pollInterval, (_) => _sweep());
    } catch (e) {
      debugPrint('QobuzWebLoginScreen setup failed: $e');
      _error = 'アプリ内ブラウザを開けませんでした';
    }
  }

  /// いったん止めて、同じ URL を自分で開き直す。**Universal Link 外し。**
  NavigationDecision _open(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return NavigationDecision.prevent;
    _passthrough = url;
    _web?.loadRequest(uri);
    return NavigationDecision.prevent;
  }

  /// 定期の一舐め。
  ///
  /// **bundle.js も取り直す。** トークンは取れたのに app_id が拾えていない
  /// ときは、ページが進めば読める場所が変わることがあるので、諦めずに
  /// 掛け直す（[_finish] が空振りしたときの受け皿）。
  void _sweep() {
    _inject(QobuzWebLogin.captureScript);
    if (_done || _harvesting) return;
    if (_token == null) return;
    if (_appId?.isNotEmpty ?? false) return;
    _harvesting = true;
    _inject(QobuzWebLogin.bundleScript);
  }

  Future<void> _inject(String script) async {
    final web = _web;
    if (web == null || _done) return;
    try {
      await web.runJavaScript(script);
    } catch (e) {
      // 遷移の途中だと転ぶ。次の周期で掛かるので黙って見送る。
      debugPrint('QobuzWebLoginScreen inject skipped: $e');
    }
  }

  void _onMessage(String raw) {
    final message = QobuzWebMessage.parse(raw);
    if (message == null || _done) return;
    if (message.isAuth) {
      final token = message.token;
      // **トークンだけで先へ進む。** app_id が付いてこないことがあるので
      // 揃うまで待たない——bundle.js 側の app_id で補える（[_finish]）。
      if (token == null) return;
      final appId = message.appId ?? _appId;
      if (_appId == appId && _token == token) return;
      setState(() {
        _appId = appId;
        _token = token;
      });
      // トークンが取れたら bundle.js を読みに行く。**1 回だけ。**
      if (!_harvesting) {
        _harvesting = true;
        _inject(QobuzWebLogin.bundleScript);
      }
      return;
    }
    if (message.isBundle) {
      final keys = QobuzBundle.extract(message.bundle ?? '');
      _finish(secrets: keys.secrets, fallbackAppId: keys.appId);
      return;
    }
    if (message.isError) {
      // 秘密が取れなくてもトークンは活きている。**そこまでは持ち帰る。**
      debugPrint('QobuzWebLoginScreen bundle failed: ${message.message}');
      _finish(secrets: const []);
    }
  }

  /// 持ち帰って閉じる。
  ///
  /// [fallbackAppId] は bundle.js から読めた `app_id`。**通信から拾えなかった
  /// ときの補い**で、ヘッダにもクエリにも出てこないページで効く。
  void _finish({required List<String> secrets, String? fallbackAppId}) {
    final appId = (_appId?.isNotEmpty ?? false) ? _appId! : (fallbackAppId ?? '');
    final token = _token;
    if (token == null || _done) return;
    if (appId.isEmpty) {
      // **黙って閉じない。** ここで pop すると設定画面には何も起きず、
      // 「ログインしたのに無反応」にしか見えない。
      if (!mounted) return;
      setState(() {
        _harvesting = false;
        _error = 'ログインは取れましたが app_id を拾えませんでした。'
            'Web プレイヤーの中を少し操作して（アルバムを開くなど）'
            'ください。もう一度探します';
      });
      return;
    }
    _done = true;
    _poll?.cancel();
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(QobuzWebLoginResult(appId: appId, token: token, secrets: secrets));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return Scaffold(
      backgroundColor: AppColors.frameBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 20, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '閉じる',
                    icon: Icon(
                      Icons.close,
                      color: AppColors.white(0.5),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const CapsLabel('QOBUZ にログイン'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _token == null ? Icons.info_outline : Icons.check_circle,
                    size: 16,
                    color: _token == null
                        ? AppColors.white(0.4)
                        : AppColors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error ??
                          (_token == null
                              ? 'いつもどおりログインしてください。'
                                    '鍵とトークンは自動で取り込みます'
                              : '鍵を取り込んでいます…'),
                      style: AppText.body(
                        12,
                        color: AppColors.white(0.55),
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: web == null
                  ? const SizedBox.shrink()
                  : WebViewWidget(controller: web),
            ),
          ],
        ),
      ),
    );
  }
}
