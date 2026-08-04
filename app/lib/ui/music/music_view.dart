import 'package:flutter/material.dart';

import '../../state/music_section.dart';
import '../../theme/tokens.dart';
import '../controller_screen.dart';
import '../login_screen.dart';
import '../widgets/atoms.dart';

/// music モードの入口。サインイン状態で出し分けるだけ。
///
/// 中身（[ControllerScreen]）は今までどおり。`AppShell` の下に入れても
/// 作り直されないので、home から戻ってきてもアートワークは出たまま。
class MusicView extends StatelessWidget {
  const MusicView({super.key, required this.section, this.onOpenMenu});

  final MusicSection section;

  /// home へ切り替える Drawer を開く。
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: section,
      builder: (context, _) {
        if (!section.isRestored) {
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
        final player = section.player;
        final newReleases = section.newReleases;
        if (player == null || newReleases == null) {
          final login = LoginScreen(auth: section.auth);
          final onOpenMenu = this.onOpenMenu;
          if (onOpenMenu == null) return login;
          return Stack(
            children: [
              Positioned.fill(child: login),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 4,
                left: 4,
                child: MenuButton(onPressed: onOpenMenu),
              ),
            ],
          );
        }
        return ControllerScreen(
          // サインアウト → 再サインインで状態を持ち越さない。
          key: ValueKey(player),
          controller: player,
          newReleases: newReleases,
          resolver: section.resolver,
          onSignOut: section.auth.signOut,
          needsReauthorization: section.auth.needsReauthorization,
          authBusy: section.auth.isBusy,
          onReauthorize: section.auth.reauthorize,
          onOpenMenu: onOpenMenu,
        );
      },
    );
  }
}
