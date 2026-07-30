import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/auth_service.dart';
import 'services/spotify_api.dart';
import 'state/player_controller.dart';
import 'theme/tokens.dart';
import 'ui/controller_screen.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 常に暗い画面なのでステータスバーは明色固定。
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const SpotifyRemoteApp());
}

class SpotifyRemoteApp extends StatefulWidget {
  const SpotifyRemoteApp({super.key});

  @override
  State<SpotifyRemoteApp> createState() => _SpotifyRemoteAppState();
}

class _SpotifyRemoteAppState extends State<SpotifyRemoteApp> {
  late final AuthService _auth = AuthService();
  late final SpotifyApi _api = SpotifyApi(_auth);

  /// サインインするたびに作り直す。前のポーリングを確実に止めるため。
  PlayerController? _player;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_syncPlayer);
    _auth.restore();
  }

  @override
  void dispose() {
    _auth.removeListener(_syncPlayer);
    _player?.dispose();
    _auth.dispose();
    super.dispose();
  }

  void _syncPlayer() {
    final signedIn = _auth.isSignedIn;
    if (signedIn && _player == null) {
      setState(() => _player = PlayerController(_api));
    } else if (!signedIn && _player != null) {
      final old = _player;
      setState(() => _player = null);
      old?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotify Remote',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: ListenableBuilder(
        listenable: _auth,
        builder: (context, _) {
          if (!_auth.isRestored) {
            return const Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(
                child: SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    color: AppColors.green,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            );
          }
          final player = _player;
          if (player == null) return LoginScreen(auth: _auth);
          return ControllerScreen(
            // サインアウト → 再サインインで状態を持ち越さない。
            key: ValueKey(player),
            controller: player,
            onSignOut: _auth.signOut,
          );
        },
      ),
    );
  }
}
