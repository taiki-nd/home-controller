import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/app_flags.dart';
import 'state/home_controller.dart';
import 'state/music_section.dart';
import 'state/qobuz_controller.dart';
import 'theme/tokens.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 常に暗い画面なのでステータスバーは明色固定。
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const HomeCtlApp());
}

/// home（Home Assistant）と music（Spotify）と hi-res（Qobuz → WiiM）を束ねる。
///
/// music と hi-res は [AppFlags.enableMusic] が false のビルドでは
/// **そもそも作らない。**
/// 実行時に隠すのではなくコンパイル時に落とすので、公開バイナリからは
/// Spotify のコードパスに到達できない（`docs/release-strategy.md` §3）。
class HomeCtlApp extends StatefulWidget {
  const HomeCtlApp({super.key});

  @override
  State<HomeCtlApp> createState() => _HomeCtlAppState();
}

class _HomeCtlAppState extends State<HomeCtlApp> {
  final HomeController _home = HomeController();
  final MusicSection? _music = AppFlags.enableMusic ? MusicSection() : null;
  final QobuzController? _assistant =
      AppFlags.enableMusic ? QobuzController() : null;

  @override
  void dispose() {
    _home.dispose();
    _music?.dispose();
    _assistant?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'home-ctl',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AppShell(home: _home, music: _music, assistant: _assistant),
    );
  }
}
