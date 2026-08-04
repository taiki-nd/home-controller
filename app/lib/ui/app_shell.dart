import 'dart:async';

import 'package:flutter/material.dart';

import '../state/home_controller.dart';
import '../state/music_section.dart';
import '../theme/tokens.dart';
import 'home/ha_setup_screen.dart';
import 'home/home_screen.dart';
import 'music/music_view.dart';
import 'widgets/atoms.dart';

enum AppMode { music, home }

/// home と music を最上位で分ける外枠。
///
/// **`Navigator.push` ではなく `IndexedStack`。** 作り直すと music に戻る
/// たびに `PlayerController` が再生成されてアートワークが一瞬消え、HA の
/// WebSocket も張り直しになる。壁掛けだとこのチラつきが目立つ
/// （`docs/home-assistant-integration.md` §10）。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.home, this.music});

  final HomeController home;

  /// null なら music を出さない（`ENABLE_MUSIC=false` の公開ビルド）。
  final MusicSection? music;

  /// 無操作で music に戻るまで。
  ///
  /// **焼きつき対策の本命。** 全画面の固定グリッドはこのアプリで一番焼きつきに
  /// 弱い絵なので、home は「用があるときだけ開く画面」と割り切る。
  /// ハンバーガーの弱点（現在地が見えない）も、放っておけば必ず music に
  /// 戻っていることで実質的に消える。
  static const idleTimeout = Duration(minutes: 3);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  late AppMode _mode = widget.music == null ? AppMode.home : AppMode.music;
  Timer? _idle;

  bool get _hasMusic => widget.music != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.home.start();
    widget.music?.start();
  }

  @override
  void dispose() {
    _idle?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 前面にいない間は HA との接続を張りっぱなしにしない。
    widget.home.setForeground(state == AppLifecycleState.resumed);
  }

  void _switch(AppMode mode) {
    if (_mode != mode) setState(() => _mode = mode);
    _restartIdle();
  }

  /// 画面のどこかを触ったら計り直す。
  void _restartIdle() {
    _idle?.cancel();
    if (_mode != AppMode.home || !_hasMusic) return;
    _idle = Timer(AppShell.idleTimeout, () {
      if (mounted) setState(() => _mode = AppMode.music);
    });
  }

  void _openMenu() => _scaffoldKey.currentState?.openDrawer();

  Future<void> _openSetup() async {
    Navigator.of(context).pop();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HaSetupScreen(
          controller: widget.home,
          isRoot: false,
          onOpenMenu: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final music = widget.music;
    final home = HomeScreen(controller: widget.home, onOpenMenu: _openMenu);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _restartIdle(),
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppColors.frameBg,
        // 曲送りの水平スワイプ（swipe_skip.dart）とエッジドラッグがぶつかる。
        // 曲を送るつもりで Drawer が出るのは壁掛けだとストレスが大きいので、
        // ☰ のタップ専用にする。
        drawerEnableOpenDragGesture: false,
        drawer: _ShellDrawer(
          mode: _mode,
          home: widget.home,
          music: music,
          onSelect: (mode) {
            Navigator.of(context).pop();
            _switch(mode);
          },
          onOpenSetup: _openSetup,
        ),
        body: music == null
            ? home
            : IndexedStack(
                index: _mode == AppMode.music ? 0 : 1,
                children: [
                  MusicView(section: music, onOpenMenu: _openMenu),
                  home,
                ],
              ),
      ),
    );
  }
}

class _ShellDrawer extends StatelessWidget {
  const _ShellDrawer({
    required this.mode,
    required this.home,
    required this.music,
    required this.onSelect,
    required this.onOpenSetup,
  });

  final AppMode mode;
  final HomeController home;
  final MusicSection? music;
  final ValueChanged<AppMode> onSelect;
  final VoidCallback onOpenSetup;

  @override
  Widget build(BuildContext context) {
    final music = this.music;
    return Drawer(
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: ListenableBuilder(
          // 開いた瞬間に両方の要約が見えるようにする。片方の状態を見るためだけに
          // モードを切り替えることが無くなる。
          listenable: Listenable.merge([home, ?music]),
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: CapsLabel('HOME-CTL'),
                ),
                if (music != null)
                  _ModeRow(
                    icon: Icons.music_note,
                    label: 'MUSIC',
                    subtitle: music.drawerSubtitle,
                    selected: mode == AppMode.music,
                    onTap: () => onSelect(AppMode.music),
                  ),
                _ModeRow(
                  icon: Icons.home_outlined,
                  label: 'HOME',
                  subtitle: _homeSubtitle(home),
                  selected: mode == AppMode.home,
                  onTap: () => onSelect(AppMode.home),
                ),
                const SizedBox(height: 8),
                Divider(color: AppColors.white(0.08), height: 24),
                _ModeRow(
                  icon: Icons.settings_outlined,
                  label: '接続設定',
                  subtitle: home.connection?.baseUrl.host,
                  selected: false,
                  onTap: onOpenSetup,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _homeSubtitle(HomeController home) => switch (home.status) {
    HaStatus.needsSetup => '未設定',
    HaStatus.authFailed => 'トークンが拒否されました',
    HaStatus.connecting => '接続中…',
    HaStatus.offline => 'オフライン',
    HaStatus.connected =>
      home.onCount == 0 ? 'すべて消灯' : '${home.onCount} つ点灯',
  };
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : AppColors.white(0.6);
    return HoverRow(
      onTap: onTap,
      radius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.caps(
                    12,
                    color,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body(12, color: AppColors.white(0.45)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
