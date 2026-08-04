import 'package:flutter/material.dart';

import '../models/release_models.dart';
import '../models/spotify_models.dart';
import '../services/spotify_api.dart';
import '../state/new_releases_controller.dart';
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
    required this.newReleases,
    required this.resolver,
    required this.onSignOut,
    this.needsReauthorization = false,
    this.authBusy = false,
    this.onReauthorize,
    this.onOpenMenu,
  });

  final PlayerController controller;
  final NewReleasesController newReleases;
  final ReleaseResolver resolver;
  final VoidCallback onSignOut;

  /// scope を足したあと、まだ再連携していない（[AuthService.needsReauthorization]）。
  final bool needsReauthorization;
  final bool authBusy;
  final VoidCallback? onReauthorize;

  /// home へ切り替える Drawer を開く。null なら出さない（music 単体で使うとき）。
  final VoidCallback? onOpenMenu;

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen>
    with WidgetsBindingObserver {
  Track? _pendingPlayNow;
  PlaylistSummary? _pendingPlaylist;
  SpotifyAlbumMatch? _pendingAlbum;

  /// 再連携バナーを閉じたか。次の起動ではまた出る（永続化しない）。
  bool _reauthDismissed = false;

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

        // ステータスバー（時刻・バッテリー）の帯。SafeArea で画面ごと下げると
        // この帯が背景グラデ 1 枚になり、左のアートワーク面と右のレールが
        // 帯の中で切れずにつながってしまう。レール側は天まで塗りたいので、
        // 画面は全面のまま、中身だけこのぶん下げる。
        final topPad = MediaQuery.paddingOf(context).top;
        // 停止バナーは自前でステータスバーぶんまで塗るので、出ている間は
        // 帯の高さもバナーが持つ。中身はさらにバナーの高さだけ下がる。
        final contentTop =
            topPad + (controller.showStoppedBanner ? StoppedBanner.height : 0);

        // デバイス一覧の緑の点は、開く前に見えているピルの点の真下に来ないと
        // 横にずれて見える。ピル側の x から逆算して置く。
        final popoverLeft = DevicePopover.leftForPillDotX(
          wide ? TabletLayout.devicePillDotX : PhoneLayout.devicePillDotX,
        );

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
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: wide
                          ? TabletLayout(
                              controller: controller,
                              newReleases: widget.newReleases,
                              onPlayNow: _askPlayNow,
                              onPlayPlaylist: _askPlaylist,
                              onPlayRelease: _askRelease,
                              topInset: contentTop,
                              attribution: _attributionSlot(controller),
                            )
                          : PhoneLayout(
                              controller: controller,
                              newReleases: widget.newReleases,
                              onPlayNow: _askPlayNow,
                              onPlayPlaylist: _askPlaylist,
                              onPlayRelease: _askRelease,
                              topInset: contentTop,
                              attribution: _attributionSlot(
                                controller,
                                compact: true,
                              ),
                            ),
                    ),

                    if (widget.onOpenMenu != null)
                      Positioned(
                        top: contentTop,
                        left: 4,
                        child: MenuButton(onPressed: widget.onOpenMenu!),
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
                        top: contentTop,
                        left: 0,
                        right: 0,
                        child: ErrorBanner(
                          message: controller.errorBanner!,
                          onDismiss: controller.dismissError,
                        ),
                      )
                    // エラーと同じ場所なので、出るときはエラーを優先する。
                    else if (widget.needsReauthorization && !_reauthDismissed)
                      Positioned(
                        top: contentTop,
                        left: 0,
                        right: 0,
                        child: ReauthBanner(
                          busy: widget.authBusy,
                          onReauthorize: widget.onReauthorize ?? () {},
                          onDismiss: () =>
                              setState(() => _reauthDismissed = true),
                        ),
                      ),

                    if (controller.devicesOpen)
                      Positioned(
                        top: contentTop + (wide ? 86 : 100),
                        left: popoverLeft,
                        // スマホは左右対称に伸ばす。
                        right: wide ? null : popoverLeft,
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

                    if (_pendingAlbum != null)
                      Positioned.fill(
                        child: ReleasePlayConfirm(
                          album: _pendingAlbum!,
                          queueCount: controller.upNext.length,
                          onConfirm: () {
                            final album = _pendingAlbum!;
                            setState(() => _pendingAlbum = null);
                            controller.playAlbum(album);
                          },
                          onCancel: () => setState(() => _pendingAlbum = null),
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
        );
      },
    );
  }

  Widget _attributionSlot(PlayerController controller, {bool compact = false}) {
    return _Attribution(
      controller: controller,
      onLongPress: _confirmSignOut,
      compact: compact,
    );
  }

  void _askPlayNow(Track track) => setState(() => _pendingPlayNow = track);

  /// 新譜の行を押したとき。**ここで初めて Spotify を叩く**（設計メモ §14）。
  /// リスト全体を解決しないのは、1 行あたり検索 1 回のコストがかかるため。
  Future<void> _askRelease(NewRelease release) async {
    final controller = widget.controller;
    if (release.isUpcoming(DateTime.now())) {
      // 未発売は Spotify にまだ存在しない。探しに行くだけ無駄になる。
      controller.showToast('${release.dateLabel(DateTime.now())}に発売予定です');
      return;
    }
    controller.showToast('Spotify で探しています…');
    try {
      final album = await widget.resolver.resolve(release);
      if (!mounted) return;
      if (album == null) {
        controller.showToast('Spotify で見つかりませんでした');
        return;
      }
      setState(() => _pendingAlbum = album);
    } on SpotifyApiException catch (e) {
      if (mounted) controller.showToast(e.message);
    }
  }

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
              // デザインのこの位置は「1716 kbps」だったので、数字だけ置くと
              // 音質表示に見えてしまう。音量だと分かるアイコンを必ず添える。
              Icon(
                volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                size: compact ? 11 : 13,
                color: AppColors.white(0.72),
              ),
              const SizedBox(width: 4),
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
