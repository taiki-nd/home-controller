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
    this.onSeek,
  });

  final PlaybackSurface controller;
  final double barHeight;
  final double labelSize;

  /// バーを叩いて頭出しする口。**渡さなければ触れないバー。**
  /// Spotify Connect 側は機器がシークを拒むことがあるので渡していない。
  final ValueChanged<Duration>? onSeek;

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
            _Seekable(
              onSeek: onSeek,
              duration: duration,
              child: ClipRRect(
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
/// iPad は 42 / 56 / 42 の塗りボタン、iPhone は前後を透明にして 74 の主ボタン。
/// バーを叩いた位置で頭出しする覆い。
///
/// **[onSeek] が null なら素通し。** 触れるバーと触れないバーを 1 つの
/// [ProgressRow] で兼ねるために挟んでいる（`HitTestBehavior.opaque` を
/// 常に掛けると、シークできない側でもタップを吸ってしまう）。
class _Seekable extends StatelessWidget {
  const _Seekable({
    required this.onSeek,
    required this.duration,
    required this.child,
  });

  final ValueChanged<Duration>? onSeek;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final onSeek = this.onSeek;
    if (onSeek == null || duration == Duration.zero) return child;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          final ratio = (details.localPosition.dx / constraints.maxWidth).clamp(
            0.0,
            1.0,
          );
          onSeek(duration * ratio);
        },
        child: child,
      ),
    );
  }
}

class TransportControls extends StatelessWidget {
  const TransportControls({
    super.key,
    required this.controller,
    required this.compact,
  });

  final PlaybackSurface controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.controlsEnabled;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SideButton(
          icon: Icons.skip_previous_rounded,
          filled: !compact,
          size: compact ? kMinTapTarget : 42,
          onTap: enabled ? controller.skipPrevious : null,
          semanticLabel: '前の曲',
        ),
        SizedBox(width: compact ? 26 : 16),
        _PlayButton(controller: controller, size: compact ? 74 : 56),
        SizedBox(width: compact ? 26 : 16),
        _SideButton(
          icon: Icons.skip_next_rounded,
          filled: !compact,
          size: compact ? kMinTapTarget : 42,
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
              size: filled ? 20 : 30,
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

  final PlaybackSurface controller;
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

/// 右レール / ボトムシート上部のタブ。
///
/// ラベルは index ではなく [RailTab] で引く。[RailTab] に値を足したら
/// [defaultLabel] の switch がコンパイルエラーになるので、付け忘れができない。
/// 幅の狭いスマホだけ [labels] で短い文言に差し替える。
class RailTabs extends StatelessWidget {
  const RailTabs({
    super.key,
    required this.selected,
    required this.onSelect,
    this.labels,
  });

  final RailTab selected;
  final ValueChanged<RailTab> onSelect;

  /// 差し替えたいものだけ入れる。無いものは [defaultLabel]。
  final Map<RailTab, String>? labels;

  static String defaultLabel(RailTab tab) => switch (tab) {
    RailTab.queue => 'Up next',
    RailTab.search => 'Add tracks',
    RailTab.playlists => 'Playlists',
    RailTab.newReleases => 'New',
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (index, tab) in RailTab.values.indexed) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            child: TabButton(
              label: labels?[tab] ?? defaultLabel(tab),
              active: selected == tab,
              onTap: () => onSelect(tab),
            ),
          ),
        ],
      ],
    );
  }
}

/// タブの並び。**音源に依らない形**——Spotify は [RailTab]、Qobuz は
/// `QobuzTab` と持ち物が違うので、共有するのは見た目だけにする。
class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({super.key, required this.tabs});

  final List<TabButton> tabs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (index, tab) in tabs.indexed) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(child: tab),
        ],
      ],
    );
  }
}

class TabButton extends StatelessWidget {
  const TabButton({
    super.key,
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
