import 'package:flutter/material.dart';

import '../models/spotify_models.dart';
import '../state/player_controller.dart';
import '../theme/tokens.dart';
import 'phone_layout.dart';
import 'tablet_layout.dart';
import 'widgets/atoms.dart';
import 'widgets/overlays.dart';

/// プレイヤー画面の外枠。背景・レイアウト切り替え・全オーバーレイをここで束ねる。
class ControllerScreen extends StatefulWidget {
  const ControllerScreen({
    super.key,
    required this.controller,
    required this.onSignOut,
  });

  final PlayerController controller;
  final VoidCallback onSignOut;

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen>
    with WidgetsBindingObserver {
  Track? _pendingPlayNow;
  PlaylistSummary? _pendingPlaylist;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンドではポーリングを止める（設計メモ §8）。
    widget.controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= kTabletBreakpoint;
        final stopped = controller.isStopped;
        final palette = controller.palette;

        // 停止中は配色を落として「鳴っていない」ことを画面全体で示す。
        final gradient = stopped
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF14140F), AppColors.frameBg],
                stops: [0, 0.7],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette.deep, palette.accent, AppColors.frameBg],
                stops: const [0, 0.55, 1],
              );

        return Scaffold(
          backgroundColor: AppColors.frameBg,
          body: GestureDetector(
            // ポップオーバーの外側タップで閉じる。
            behavior: HitTestBehavior.translucent,
            onTap: controller.closeDevicePopover,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              decoration: BoxDecoration(gradient: gradient),
              child: DecoratedBox(
                // アートワーク由来の色が明るいときに文字が沈まないよう暗幕を重ねる。
                decoration: BoxDecoration(
                  gradient: wide
                      ? RadialGradient(
                          center: Alignment.topLeft,
                          radius: 1.4,
                          colors: [
                            Colors.black.withValues(alpha: 0.15),
                            Colors.black.withValues(alpha: 0.72),
                          ],
                          stops: const [0, 0.75],
                        )
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.25),
                            Colors.black.withValues(alpha: 0.8),
                          ],
                        ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: wide
                            ? Padding(
                                padding: EdgeInsets.only(
                                  top: controller.showStoppedBanner
                                      ? StoppedBanner.height
                                      : 0,
                                ),
                                child: TabletLayout(
                                  controller: controller,
                                  onPlayNow: _askPlayNow,
                                  onPlayPlaylist: _askPlaylist,
                                  attribution: _Attribution(
                                    controller: controller,
                                    onLongPress: _confirmSignOut,
                                  ),
                                ),
                              )
                            : PhoneLayout(
                                controller: controller,
                                onPlayNow: _askPlayNow,
                                onPlayPlaylist: _askPlaylist,
                                topInset: controller.showStoppedBanner
                                    ? StoppedBanner.height
                                    : 0,
                                attribution: _Attribution(
                                  controller: controller,
                                  onLongPress: _confirmSignOut,
                                  compact: true,
                                ),
                              ),
                      ),

                      if (controller.showStoppedBanner)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: StoppedBanner(
                            onResume: () =>
                                controller.openSheet(RailTab.search),
                          ),
                        ),

                      if (controller.errorBanner != null)
                        Positioned(
                          top: controller.showStoppedBanner
                              ? StoppedBanner.height
                              : 0,
                          left: 0,
                          right: 0,
                          child: ErrorBanner(
                            message: controller.errorBanner!,
                            onDismiss: controller.dismissError,
                          ),
                        ),

                      if (controller.devicesOpen)
                        Positioned(
                          top: wide ? 86 : 100,
                          left: wide ? 40 : 18,
                          right: wide ? null : 18,
                          child: DevicePopover(
                            devices: controller.devices,
                            activeDeviceId: controller.activeDevice?.id,
                            onPick: controller.pickDevice,
                            onRescan: controller.rescanDevices,
                            width: wide ? 340 : double.infinity,
                          ),
                        ),

                      if (controller.deviceLost)
                        Positioned.fill(
                          child: NoDeviceOverlay(
                            onRescan: controller.rescanDevices,
                            onDismiss: controller.dismissNoDevice,
                          ),
                        ),

                      if (_pendingPlayNow != null)
                        Positioned.fill(
                          child: PlayNowConfirm(
                            track: _pendingPlayNow!,
                            queueCount: controller.upNext.length,
                            onConfirm: () {
                              final track = _pendingPlayNow!;
                              setState(() => _pendingPlayNow = null);
                              controller.playNow(track);
                            },
                            onCancel: () =>
                                setState(() => _pendingPlayNow = null),
                          ),
                        ),

                      if (_pendingPlaylist != null)
                        Positioned.fill(
                          child: PlaylistConfirm(
                            playlist: _pendingPlaylist!,
                            queueCount: controller.upNext.length,
                            initialShuffle: controller.shuffleOn,
                            onConfirm: (shuffle) {
                              final playlist = _pendingPlaylist!;
                              setState(() => _pendingPlaylist = null);
                              controller.playPlaylist(
                                playlist,
                                shuffle: shuffle,
                              );
                            },
                            onCancel: () =>
                                setState(() => _pendingPlaylist = null),
                          ),
                        ),

                      if (controller.toast != null)
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 34,
                          child: Center(child: AppToast(text: controller.toast!)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _askPlayNow(Track track) => setState(() => _pendingPlayNow = track);

  void _askPlaylist(PlaylistSummary playlist) =>
      setState(() => _pendingPlaylist = playlist);

  Future<void> _confirmSignOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'Spotify からサインアウト',
          style: AppText.body(18, weight: FontWeight.w900),
        ),
        content: Text(
          '保存したトークンを消して、ログイン画面に戻ります。',
          style: AppText.body(14, color: AppColors.white(0.7), height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'サインアウト',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (ok ?? false) widget.onSignOut();
  }
}

/// Spotify への帰属表示（設計メモ §12 で必須）と、いま鳴らしている音量。
///
/// デザインではここが「1716 kbps | 16bit | 44.1kHz」だが、
/// **Spotify Web API はビットレート・ビット深度・サンプルレートを一切返さない。**
/// 実測できない数値を出すと嘘になるので、同じピルの枠に
/// 「取得できる本物の情報（帰属表示 + volume_percent）」を入れている。
class _Attribution extends StatelessWidget {
  const _Attribution({
    required this.controller,
    required this.onLongPress,
    this.compact = false,
  });

  final PlayerController controller;
  final VoidCallback onLongPress;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final volume = controller.activeDevice?.volumePercent;
    return GestureDetector(
      // 長押しでサインアウト。普段は出さない。
      onLongPress: onLongPress,
      child: GlassPill(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 7 : 9,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.graphic_eq_rounded,
              size: compact ? 11 : 13,
              color: AppColors.green,
            ),
            const SizedBox(width: 6),
            Text(
              compact ? 'SPOTIFY' : 'SPOTIFY CONNECT',
              style: AppText.grotesk(
                size: compact ? 10 : 13,
                weight: 700,
                color: AppColors.white(0.72),
                letterSpacing: 0.6,
              ),
            ),
            if (volume != null) ...[
              const SizedBox(width: 8),
              Text(
                '|',
                style: AppText.grotesk(
                  size: compact ? 10 : 13,
                  color: AppColors.white(0.25),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$volume%',
                style: AppText.grotesk(
                  size: compact ? 10 : 13,
                  color: AppColors.white(0.72),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
