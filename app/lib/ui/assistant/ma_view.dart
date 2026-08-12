import 'package:flutter/material.dart';

import '../../models/ma_models.dart';
import '../../state/ma_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';
import '../widgets/marquee_text.dart';
import 'ma_setup_screen.dart';

/// Music Assistant モードの入口（`docs/music-assistant-integration.md` §6）。
///
/// music（Spotify）とは**混ぜない。** 壁掛けで人が入れ替わりながら触るので、
/// いまどちらを操作しているのかが曖昧だと事故る。作法だけ music に寄せる。
class MaView extends StatelessWidget {
  const MaView({super.key, required this.controller, this.onOpenMenu});

  final MaController controller;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.needsSetup) {
          return MaSetupScreen(
            controller: controller,
            onOpenMenu: onOpenMenu ?? () {},
          );
        }
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                _Header(controller: controller, onOpenMenu: onOpenMenu),
                if (controller.errorBanner != null)
                  _ErrorBanner(controller: controller),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= kTabletBreakpoint;
                      final nowPlaying = _NowPlaying(
                        controller: controller,
                        compact: !wide,
                      );
                      final panel = _Panel(controller: controller);
                      if (!wide) {
                        return Column(
                          children: [
                            nowPlaying,
                            Expanded(child: panel),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 5, child: Center(child: nowPlaying)),
                          SizedBox(
                            width: 1,
                            child: ColoredBox(color: AppColors.white(0.06)),
                          ),
                          Expanded(flex: 4, child: panel),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// ☰ / モード名 / 出力先ピル。
class _Header extends StatelessWidget {
  const _Header({required this.controller, this.onOpenMenu});

  final MaController controller;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    final player = controller.selectedPlayer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
      child: Row(
        children: [
          if (onOpenMenu != null) MenuButton(onPressed: onOpenMenu!),
          const SizedBox(width: 2),
          const CapsLabel('HI-RES'),
          const Spacer(),
          GlassPill(
            onTap: controller.players.isEmpty
                ? null
                : () => _pickPlayer(context, controller),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(
                  color: switch (controller.status) {
                    MaStatus.connected =>
                      controller.isPlaying ? AppColors.green : AppColors.dotIdle,
                    MaStatus.connecting => AppColors.amber,
                    _ => AppColors.danger,
                  },
                  pulse: controller.isPlaying,
                ),
                const SizedBox(width: 8),
                CapCentered(
                  fontSize: 13,
                  child: Text(
                    player?.name ?? _statusText(controller.status),
                    style: AppText.body(13, color: AppColors.white(0.8)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusText(MaStatus status) => switch (status) {
    MaStatus.connecting => '接続中…',
    MaStatus.offline => 'オフライン',
    _ => '出力先なし',
  };

  static Future<void> _pickPlayer(
    BuildContext context,
    MaController controller,
  ) async {
    final selected = await showModalBottomSheet<MaPlayer>(
      context: context,
      backgroundColor: AppColors.popover,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.dialog),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: CapsLabel('出力先'),
            ),
            for (final player in controller.players)
              HoverRow(
                onTap: () => Navigator.of(context).pop(player),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.speaker_outlined,
                      size: 18,
                      color: player.playerId ==
                              controller.selectedPlayer?.playerId
                          ? Colors.white
                          : AppColors.white(0.5),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        player.name,
                        style: AppText.body(15, color: Colors.white),
                      ),
                    ),
                    if (player.volumeLevel != null)
                      Text(
                        '${player.volumeLevel}',
                        style: AppText.grotesk(
                          size: 12,
                          color: AppColors.white(0.4),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (selected != null) await controller.selectPlayer(selected);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.controller});

  final MaController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.14),
        borderRadius: AppRadius.row,
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              controller.errorBanner!,
              style: AppText.body(13, color: AppColors.white(0.85)),
            ),
          ),
          TextButton(
            onPressed: controller.retry,
            child: Text(
              '再試行',
              style: AppText.body(13, color: AppColors.white(0.85)),
            ),
          ),
          IconButton(
            onPressed: controller.dismissError,
            tooltip: '閉じる',
            icon: Icon(Icons.close, size: 16, color: AppColors.white(0.5)),
          ),
        ],
      ),
    );
  }
}

/// アートワーク・曲名・シークバー・トランスポート。
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.controller, required this.compact});

  final MaController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final item = controller.currentItem;
    final base = controller.imageBase;
    final art = compact ? 148.0 : 260.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: compact ? 12 : 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Artwork(
            url: base == null ? null : item?.image?.url(base, size: 512),
            size: art,
          ),
          SizedBox(height: compact ? 16 : 24),
          SizedBox(
            width: double.infinity,
            child: MarqueeText(
              item?.title ?? '停止中',
              style: AppText.body(
                compact ? 19 : 24,
                weight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item?.artist ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.body(14, color: AppColors.white(0.55)),
          ),
          if (item?.provider != null) ...[
            const SizedBox(height: 10),
            CapsLabel(item!.provider!, size: 10),
          ],
          SizedBox(height: compact ? 16 : 24),
          _Progress(controller: controller),
          SizedBox(height: compact ? 12 : 18),
          _Transport(controller: controller, compact: compact),
        ],
      ),
    );
  }
}

/// シークバー。**ここだけ毎秒描き直す**（`MaController.progressTick`）。
class _Progress extends StatelessWidget {
  const _Progress({required this.controller});

  final MaController controller;

  static const _barHeight = 6.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.progressTick,
      builder: (context, _) {
        final position = controller.position;
        final duration = controller.duration;
        final fraction = controller.progressFraction;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: duration == Duration.zero
                      ? null
                      : (details) {
                          final ratio =
                              (details.localPosition.dx / constraints.maxWidth)
                                  .clamp(0.0, 1.0);
                          controller.seek(duration * ratio);
                        },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: SizedBox(
                      height: _barHeight,
                      child: LinearProgressIndicator(
                        value: fraction,
                        backgroundColor: AppColors.white(0.10),
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatDuration(position),
                  style: AppText.grotesk(
                    size: 13,
                    color: AppColors.white(0.5),
                  ),
                ),
                Text(
                  duration == Duration.zero
                      ? '--:--'
                      : '-${formatDuration(duration - position)}',
                  style: AppText.grotesk(
                    size: 13,
                    color: AppColors.white(0.5),
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

class _Transport extends StatelessWidget {
  const _Transport({required this.controller, required this.compact});

  final MaController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final queue = controller.queue;
    // 接続していてキューがある間だけ押せる。`queue` は各所で中身も見るので、
    // bool 変数越しではなく毎回 null 判定を書く（Dart は bool からは
    // 昇格してくれない）。
    final enabled = controller.status == MaStatus.connected && queue != null;
    final repeatMode = queue?.repeatMode ?? MaRepeatMode.off;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _IconToggle(
          icon: Icons.shuffle_rounded,
          active: queue?.shuffleEnabled ?? false,
          onTap: queue == null || !enabled
              ? null
              : () => controller.setShuffle(!queue.shuffleEnabled),
          semanticLabel: 'シャッフル',
        ),
        SizedBox(width: compact ? 14 : 20),
        _RoundButton(
          icon: Icons.skip_previous_rounded,
          size: compact ? kMinTapTarget : 48,
          onTap: enabled ? controller.skipPrevious : null,
          semanticLabel: '前の曲',
        ),
        SizedBox(width: compact ? 18 : 22),
        _RoundButton(
          icon: controller.isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          size: compact ? 64 : 72,
          filled: true,
          onTap: enabled ? controller.togglePlayPause : null,
          semanticLabel: controller.isPlaying ? '一時停止' : '再生',
        ),
        SizedBox(width: compact ? 18 : 22),
        _RoundButton(
          icon: Icons.skip_next_rounded,
          size: compact ? kMinTapTarget : 48,
          onTap: enabled ? controller.skipNext : null,
          semanticLabel: '次の曲',
        ),
        SizedBox(width: compact ? 14 : 20),
        _IconToggle(
          icon: repeatMode == MaRepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          active: repeatMode != MaRepeatMode.off,
          onTap: enabled ? controller.cycleRepeat : null,
          semanticLabel: 'リピート',
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.semanticLabel,
    this.filled = false,
  });

  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final String semanticLabel;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: filled
            ? (disabled ? AppColors.white(0.25) : Colors.white)
            : Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Icon(
              icon,
              size: size * 0.52,
              color: filled
                  ? AppColors.onWhite
                  : AppColors.white(disabled ? 0.25 : 0.85),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconToggle extends StatelessWidget {
  const _IconToggle({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: semanticLabel,
      icon: Icon(
        icon,
        size: 20,
        color: active ? AppColors.green : AppColors.white(0.35),
      ),
    );
  }
}

/// キュー / 検索。
class _Panel extends StatelessWidget {
  const _Panel({required this.controller});

  final MaController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              _TabButton(
                label: 'キュー',
                count: controller.upNext.length,
                selected: controller.tab == MaTab.queue,
                onTap: () => controller.selectTab(MaTab.queue),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label: '検索',
                selected: controller.tab == MaTab.search,
                onTap: () => controller.selectTab(MaTab.search),
              ),
            ],
          ),
        ),
        Expanded(
          child: controller.tab == MaTab.queue
              ? _QueueList(controller: controller)
              : _SearchPanel(controller: controller),
        ),
        if (controller.toast != null) _Toast(controller: controller),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return HoverRow(
      onTap: onTap,
      radius: AppRadius.pill,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CapsLabel(
            label,
            size: 11,
            color: selected ? Colors.white : AppColors.white(0.4),
          ),
          if (count != null && count! > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: AppText.grotesk(
                size: 11,
                color: AppColors.white(selected ? 0.6 : 0.3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QueueList extends StatelessWidget {
  const _QueueList({required this.controller});

  final MaController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.upNext;
    if (items.isEmpty) {
      return _Empty(
        text: controller.status == MaStatus.connected
            ? 'キューは空です。検索から積んでください。'
            : '接続中…',
      );
    }
    final base = controller.imageBase;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return HoverRow(
          onTap: () => controller.playItem(item),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Artwork(
                url: base == null ? null : item.image?.url(base, size: 96),
                size: 40,
                radius: AppRadius.thumbSmall,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body(14, color: Colors.white),
                    ),
                    if (item.artist != null)
                      Text(
                        item.artist!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body(
                          12,
                          color: AppColors.white(0.45),
                        ),
                      ),
                  ],
                ),
              ),
              if (item.duration != null) ...[
                const SizedBox(width: 10),
                Text(
                  formatDuration(item.duration!),
                  style: AppText.grotesk(
                    size: 12,
                    color: AppColors.white(0.35),
                  ),
                ),
              ],
              IconButton(
                onPressed: () => controller.removeItem(item),
                tooltip: 'キューから外す',
                icon: Icon(Icons.close, size: 16, color: AppColors.white(0.35)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({required this.controller});

  final MaController controller;

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  late final _field = TextEditingController(text: widget.controller.query);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final results = controller.results;
    // トラック優先。アルバム・プレイリストはその後ろに続ける。
    final rows = [
      ...results.tracks,
      ...results.albums,
      ...results.playlists,
    ];
    final base = controller.imageBase;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: TextField(
            controller: _field,
            onChanged: controller.onQueryChanged,
            textInputAction: TextInputAction.search,
            style: AppText.body(15, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Qobuz / Spotify を横断して検索',
              hintStyle: AppText.body(15, color: AppColors.white(0.28)),
              prefixIcon: Icon(
                Icons.search,
                size: 18,
                color: AppColors.white(0.35),
              ),
              suffixIcon: controller.searchBusy
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.green,
                        ),
                      ),
                    )
                  : null,
              filled: true,
              fillColor: AppColors.white(0.06),
              border: const OutlineInputBorder(
                borderRadius: AppRadius.pill,
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? _Empty(
                  text: controller.query.trim().isEmpty
                      ? '曲名・アルバム名で検索できます。'
                      : (controller.searchBusy ? '検索中…' : '見つかりませんでした。'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final item = rows[index];
                    return HoverRow(
                      // タップは「キューの末尾へ」。**みんなで積む**のが主目的
                      // なので、いま鳴っているものを止める操作は既定にしない。
                      onTap: () => controller.enqueue(item),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Artwork(
                            url: base == null
                                ? null
                                : item.image?.url(base, size: 96),
                            size: 40,
                            radius: AppRadius.thumbSmall,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.body(
                                    14,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  [
                                    if (item.artist != null) item.artist!,
                                    item.provider,
                                  ].where((s) => s.isNotEmpty).join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.body(
                                    12,
                                    color: AppColors.white(0.45),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => controller.enqueue(
                              item,
                              option: MaQueueOption.next,
                            ),
                            tooltip: '次に再生',
                            icon: Icon(
                              Icons.playlist_play_rounded,
                              size: 20,
                              color: AppColors.white(0.5),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppText.body(13, color: AppColors.white(0.35), height: 1.7),
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.controller});

  final MaController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: HoverRow(
        onTap: controller.dismissToast,
        radius: AppRadius.pill,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            const Icon(Icons.check, size: 15, color: AppColors.green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                controller.toast!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(13, color: AppColors.white(0.8)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
