import 'package:flutter/material.dart';

import '../../state/player_controller.dart';
import '../../theme/tokens.dart';
import 'atoms.dart';

/// 進捗バー + 経過 / 残り。
///
/// [PlayerController.progressTick] だけを購読して 500ms ごとに塗り替える。
/// 全体を notifyListeners すると 2Hz でツリー全体が再ビルドされてしまう。
///
/// ただし 500ms の離散更新をそのまま幅に入れると、4 分の曲では 1 ティックあたり
/// 0.2%（幅 340px で 0.7px）しか動かず「止まって見える」。バーだけ次のティック値へ
/// 線形補間して、再ビルド頻度は 2Hz のまま描画を 60fps で滑らせる。
class ProgressRow extends StatelessWidget {
  const ProgressRow({
    super.key,
    required this.controller,
    this.barHeight = 6,
    this.labelSize = 14,
  });

  final PlayerController controller;
  final double barHeight;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.progressTick,
      builder: (context, _) {
        final position = controller.position;
        final duration = controller.duration;
        final remaining = duration - position;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: SizedBox(
                height: barHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(color: AppColors.white(0.18)),
                    ),
                    // Positioned.fill でバーの高さを渡さないと、Stack が
                    // 非配置の子に緩い制約を渡すので ColoredBox が高さ 0 に
                    // 潰れて塗りが消える（＝背景のグレーだけが見える）。
                    Positioned.fill(
                      child: TweenAnimationBuilder<double>(
                        // ティック間隔と同じ長さで線形に詰めるので、
                        // 描画は常に「1 ティック前 → 現在値」の途中を通る。
                        tween: Tween<double>(
                          begin: 0,
                          end: controller.progressFraction,
                        ),
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.linear,
                        builder: (context, value, child) =>
                            FractionallySizedBox(
                              // 既定の center だと塗りが中央から左右に伸びる。
                              alignment: Alignment.centerLeft,
                              widthFactor: value,
                              child: child,
                            ),
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatDuration(controller.isStopped ? Duration.zero : position),
                  style: AppText.grotesk(
                    size: labelSize,
                    color: AppColors.white(0.6),
                  ),
                ),
                Text(
                  '-${formatDuration(controller.isStopped ? duration : remaining)}',
                  style: AppText.grotesk(
                    size: labelSize,
                    color: AppColors.white(0.6),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// ◀◀ / 再生・一時停止 / ▶▶。
/// iPad は 62 / 84 / 62 の塗りボタン、iPhone は前後を透明にして 74 の主ボタン。
class TransportControls extends StatelessWidget {
  const TransportControls({
    super.key,
    required this.controller,
    required this.compact,
  });

  final PlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = !controller.deviceLost;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SideButton(
          icon: Icons.skip_previous_rounded,
          filled: !compact,
          size: compact ? kMinTapTarget : 62,
          onTap: enabled ? controller.skipPrevious : null,
          semanticLabel: '前の曲',
        ),
        SizedBox(width: compact ? 26 : 22),
        _PlayButton(controller: controller, size: compact ? 74 : 84),
        SizedBox(width: compact ? 26 : 22),
        _SideButton(
          icon: Icons.skip_next_rounded,
          filled: !compact,
          size: compact ? kMinTapTarget : 62,
          onTap: enabled ? controller.skipNext : null,
          semanticLabel: '次の曲',
        ),
      ],
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.icon,
    required this.filled,
    required this.size,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final bool filled;
  final double size;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: filled ? AppColors.white(0.1) : Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: filled ? 28 : 30,
              color: onTap == null ? AppColors.white(0.3) : AppColors.white(0.85),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller, required this.size});

  final PlayerController controller;
  final double size;

  @override
  Widget build(BuildContext context) {
    final playing = controller.isPlaying;
    return Semantics(
      button: true,
      label: playing ? '一時停止' : '再生',
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.7),
        child: InkWell(
          onTap: controller.togglePlayPause,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: size * 0.46,
              color: AppColors.onWhite,
            ),
          ),
        ),
      ),
    );
  }
}

/// 右レール / ボトムシート上部の 3 タブ。
class RailTabs extends StatelessWidget {
  const RailTabs({
    super.key,
    required this.selected,
    required this.onSelect,
    this.labels = const ['Up next', 'Add tracks', 'Playlists'],
  });

  final RailTab selected;
  final ValueChanged<RailTab> onSelect;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (index, tab) in RailTab.values.indexed) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            child: _TabButton(
              label: labels[index],
              active: selected == tab,
              onTap: () => onSelect(tab),
            ),
          ),
        ],
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.white(0.12) : Colors.transparent,
      borderRadius: AppRadius.row,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: kMinTapTarget,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.body(
              14,
              weight: FontWeight.w900,
              color: active ? Colors.white : AppColors.white(0.45),
            ),
          ),
        ),
      ),
    );
  }
}
