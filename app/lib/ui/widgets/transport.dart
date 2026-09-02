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

/// タブの文言。**音源で変えない。**
///
/// 壁掛けで音源を切り替えたときに、同じ場所の言葉だけ入れ替わると別のアプリに
/// 見える。music（[RailTab]）と QOBUZ（`QobuzTab`）は持ち物が違うので enum は
/// 分けたままだが、そこに載せる言葉はここ 1 か所から出す。
///
/// 「Search」ではなく「Add tracks」なのは、ここが探す場所ではなく**積む場所**
/// だから。「Playlists」ではなく「Library」なのは、QOBUZ 側にお気に入りの
/// アルバムも並ぶから。
enum TabLabel {
  upNext('Up next', 'Up next'),
  library('Library', 'Lists'),
  addTracks('Add tracks', 'Add'),
  newReleases('New', 'New');

  const TabLabel(this.full, this.short);

  final String full;

  /// スマホ用。iPhone の幅（390）に 4 つ並べると [full] は入らない。
  /// iPad と言葉が変わるのは承知の上で、はみ出すよりましと判断している。
  final String short;

  String text({required bool compact}) => compact ? short : full;
}

/// 右レール / ボトムシート上部のタブ（music）。
///
/// 並びは [RailTab] の宣言順、文言は [TabLabel]、見た目は [SegmentedTabs]。
/// QOBUZ 側（`QobuzView` の `_Tabs`）も後ろ 2 つを使うので、片方だけ違う言葉・
/// 違う見た目になることがない。
class RailTabs extends StatelessWidget {
  const RailTabs({
    super.key,
    required this.selected,
    required this.onSelect,
    this.compact = false,
  });

  final RailTab selected;
  final ValueChanged<RailTab> onSelect;

  /// スマホ。短いほうの文言を使う。
  final bool compact;

  /// [RailTab] に値を足すとここがコンパイルエラーになるので、付け忘れができない。
  static TabLabel labelOf(RailTab tab) => switch (tab) {
    RailTab.queue => TabLabel.upNext,
    RailTab.playlists => TabLabel.library,
    RailTab.search => TabLabel.addTracks,
    RailTab.newReleases => TabLabel.newReleases,
  };

  @override
  Widget build(BuildContext context) {
    return SegmentedTabs(
      tabs: [
        for (final tab in RailTab.values)
          TabButton(
            label: labelOf(tab).text(compact: compact),
            active: selected == tab,
            onTap: () => onSelect(tab),
          ),
      ],
    );
  }
}

/// タブの見た目。**音源に依らない形**——Spotify は [RailTab]、Qobuz は
/// `QobuzTab` と持ち物が違うので、共有するのは見た目だけにする。
///
/// 押しボタンが並んでいるのではなく、1 枚の台座の上をつまみが滑る形にしてある。
/// ボタン列だと「今どこにいるか」が選択中の面の有無でしか分からず、切り替えの
/// 途中が無いので、押した先へ移った感じが出ない。
///
/// つまみは選ぶたびに位置が変わるので、壁掛けでも同じ場所に焼きつかない。
/// 台座は出しっぱなしになるが、白 5% の角丸で、輝度一定の細い線は使っていない。
class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({super.key, required this.tabs});

  final List<TabButton> tabs;

  /// 台座の縁とつまみの間。
  static const _inset = 4.0;

  /// つまみが滑りきるまで。指を離してから追いつく速さ。
  static const _slide = Duration(milliseconds: 220);

  /// 台座ぶんを含めた段の高さ。中身の最小高さを決めるときに使う。
  static const height = kMinTapTarget + _inset * 2;

  @override
  Widget build(BuildContext context) {
    final selected = tabs.indexWhere((tab) => tab.active);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.white(0.05),
        borderRadius: AppRadius.row,
      ),
      child: Padding(
        padding: const EdgeInsets.all(_inset),
        child: Stack(
          children: [
            // つまみ。Row より先に置いて下に敷く（タップは上の Row が取る）。
            if (selected >= 0)
              Positioned.fill(
                child: AnimatedAlign(
                  duration: _slide,
                  curve: Curves.easeOutCubic,
                  // 等幅なので、左端 -1 から右端 +1 を等分した位置。
                  alignment: Alignment(
                    tabs.length < 2 ? 0 : -1 + 2 * selected / (tabs.length - 1),
                    0,
                  ),
                  child: FractionallySizedBox(
                    widthFactor: 1 / tabs.length,
                    heightFactor: 1,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0x24FFFFFF),
                        borderRadius: AppRadius.thumb,
                      ),
                    ),
                  ),
                ),
              ),
            Row(children: [for (final tab in tabs) Expanded(child: tab)]),
          ],
        ),
      ),
    );
  }
}

/// [SegmentedTabs] の 1 区画。面は持たない（つまみが台座の側にあるので）。
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
      color: Colors.transparent,
      borderRadius: AppRadius.thumb,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: kMinTapTarget,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
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
