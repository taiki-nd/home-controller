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

  WebViewController? _web;
  Timer? _poll;

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
        ..setNavigationDelegate(
          NavigationDelegate(
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
      _poll = Timer.periodic(
        _pollInterval,
        (_) => _inject(QobuzWebLogin.captureScript),
      );
    } catch (e) {
      debugPrint('QobuzWebLoginScreen setup failed: $e');
      _error = 'アプリ内ブラウザを開けませんでした';
    }
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
      final appId = message.appId;
      final token = message.token;
      if (appId == null || token == null) return;
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
      _finish(secrets: keys.secrets);
      return;
    }
    if (message.isError) {
      // 秘密が取れなくてもトークンは活きている。**そこまでは持ち帰る。**
      debugPrint('QobuzWebLoginScreen bundle failed: ${message.message}');
      _finish(secrets: const []);
    }
  }

  void _finish({required List<String> secrets}) {
    final appId = _appId;
    final token = _token;
    if (appId == null || token == null || _done) return;
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
