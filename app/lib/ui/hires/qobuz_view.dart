import 'package:flutter/material.dart';

import '../../models/qobuz_models.dart';
import '../../state/qobuz_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';
import '../widgets/marquee_text.dart';
import 'qobuz_setup_screen.dart';

/// hi-res モードの入口（`docs/qobuz-wiim-integration.md` §7）。
///
/// music（Spotify）とは**混ぜない。** 壁掛けで人が入れ替わりながら触るので、
/// いまどちらを操作しているのかが曖昧だと事故る。作法だけ music に寄せる。
class QobuzView extends StatelessWidget {
  const QobuzView({super.key, required this.controller, this.onOpenMenu});

  final QobuzController controller;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.needsSetup) {
          return QobuzSetupScreen(
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

/// ☰ / モード名 / WiiM のピル（タップで音量）。
class _Header extends StatelessWidget {
  const _Header({required this.controller, this.onOpenMenu});

  final QobuzController controller;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
      child: Row(
        children: [
          if (onOpenMenu != null) MenuButton(onPressed: onOpenMenu!),
          const SizedBox(width: 2),
          const CapsLabel('HI-RES'),
          const Spacer(),
          GlassPill(
            // **出力先は 1 台しかない**（IP を手で入れた WiiM）ので、
            // ここは切り替えではなく音量を出す口にしている。
            onTap: controller.status == QobuzStatus.connected
                ? () => _openVolume(context, controller)
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(
                  color: switch (controller.status) {
                    QobuzStatus.connected =>
                      controller.isPlaying
                          ? AppColors.green
                          : AppColors.dotIdle,
                    QobuzStatus.connecting => AppColors.amber,
                    _ => AppColors.danger,
                  },
                  pulse: controller.isPlaying,
                ),
                const SizedBox(width: 8),
                CapCentered(
                  fontSize: 13,
                  child: Text(
                    controller.status == QobuzStatus.connected
                        ? controller.deviceName
                        : _statusText(controller.status),
                    style: AppText.body(13, color: AppColors.white(0.8)),
                  ),
                ),
                if (controller.status == QobuzStatus.connected) ...[
                  const SizedBox(width: 10),
                  Icon(
                    controller.muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    size: 15,
                    color: AppColors.white(0.5),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${controller.volume}',
                    style: AppText.grotesk(
                      size: 12,
                      color: AppColors.white(0.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusText(QobuzStatus status) => switch (status) {
    QobuzStatus.connecting => '接続中…',
    QobuzStatus.offline => 'オフライン',
    _ => '未接続',
  };

  static Future<void> _openVolume(
    BuildContext context,
    QobuzController controller,
  ) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.popover,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.dialog),
    builder: (context) => SafeArea(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: CapsLabel(controller.deviceName),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: controller.toggleMute,
                    tooltip: 'ミュート',
                    icon: Icon(
                      controller.muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      color: controller.muted
                          ? AppColors.danger
                          : AppColors.white(0.7),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: controller.volume.toDouble(),
                      max: 100,
                      // **離した時にだけ送る。** ドラッグ中に毎フレーム
                      // httpapi を叩くと WiiM が詰まる。
                      onChanged: (_) {},
                      onChangeEnd: (value) =>
                          controller.setVolume(value.round()),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${controller.volume}',
                      textAlign: TextAlign.right,
                      style: AppText.grotesk(size: 13, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.controller});

  final QobuzController controller;

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

  final QobuzController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    final art = compact ? 148.0 : 260.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: compact ? 12 : 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Artwork(url: track?.imageUrl, size: art),
          SizedBox(height: compact ? 16 : 24),
          SizedBox(
            width: double.infinity,
            child: MarqueeText(
              track?.displayTitle ?? '停止中',
              style: AppText.body(
                compact ? 19 : 24,
                weight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            track?.artist ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.body(14, color: AppColors.white(0.55)),
          ),
          // **ハイレゾかどうかはここでしか分からない。** WiiM の画面を見に
          // 行かずに済むよう、bit/kHz を曲名の下に出す（§3 の落とし穴 6）。
          if (track?.qualityLabel != null) ...[
            const SizedBox(height: 10),
            _QualityBadge(track: track!),
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

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.track});

  final QobuzTrack track;

  @override
  Widget build(BuildContext context) {
    final hires = track.hiresStreamable;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: (hires ? AppColors.green : AppColors.white(0.5)).withValues(
          alpha: 0.14,
        ),
        borderRadius: AppRadius.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CapsLabel(
            hires ? 'HI-RES' : 'FLAC',
            size: 10,
            color: hires ? AppColors.green : AppColors.white(0.6),
          ),
          const SizedBox(width: 8),
          Text(
            track.qualityLabel!,
            style: AppText.grotesk(size: 11, color: AppColors.white(0.6)),
          ),
        ],
      ),
    );
  }
}

/// シークバー。**ここだけ毎秒描き直す**（`QobuzController.progressTick`）。
class _Progress extends StatelessWidget {
  const _Progress({required this.controller});

  final QobuzController controller;

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
                  style: AppText.grotesk(size: 13, color: AppColors.white(0.5)),
                ),
                Text(
                  duration == Duration.zero
                      ? '--:--'
                      : '-${formatDuration(duration - position)}',
                  style: AppText.grotesk(size: 13, color: AppColors.white(0.5)),
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

  final QobuzController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 接続していてキューに曲がある間だけ押せる。
    final enabled =
        controller.status == QobuzStatus.connected &&
        controller.currentItem != null;
    final repeat = controller.repeatMode;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _IconToggle(
          icon: Icons.shuffle_rounded,
          active: controller.shuffleEnabled,
          onTap: enabled
              ? () => controller.setShuffle(!controller.shuffleEnabled)
              : null,
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
          icon: repeat == QobuzRepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          active: repeat != QobuzRepeatMode.off,
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

/// キュー / ライブラリ / 検索。
class _Panel extends StatelessWidget {
  const _Panel({required this.controller});

  final QobuzController controller;

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
                selected: controller.tab == QobuzTab.queue,
                onTap: () => controller.selectTab(QobuzTab.queue),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label: 'ライブラリ',
                selected: controller.tab == QobuzTab.library,
                onTap: () => controller.selectTab(QobuzTab.library),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label: '検索',
                selected: controller.tab == QobuzTab.search,
                onTap: () => controller.selectTab(QobuzTab.search),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (controller.tab) {
            QobuzTab.queue => _QueueList(controller: controller),
            QobuzTab.library => _LibraryPanel(controller: controller),
            QobuzTab.search => _SearchPanel(controller: controller),
          },
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

/// これから鳴る曲。**並べ替えられる**——キューはこのアプリが持っているので、
/// WiiM 側の都合を気にせず入れ替えられる。
class _QueueList extends StatelessWidget {
  const _QueueList({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.upNext;
    if (items.isEmpty) {
      return _Empty(
        text: controller.status == QobuzStatus.connected
            ? 'キューは空です。ライブラリか検索から積んでください。'
            : '接続中…',
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: items.length,
      onReorder: controller.moveItem,
      buildDefaultDragHandles: false,
      itemBuilder: (context, index) {
        final item = items[index];
        return _TrackRow(
          key: ValueKey(item.id),
          title: item.track.displayTitle,
          subtitle: item.track.artist,
          imageUrl: item.track.imageUrl,
          duration: item.track.duration,
          hires: item.track.hiresStreamable,
          onTap: () => controller.playItem(item),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => controller.removeItem(item),
                tooltip: 'キューから外す',
                icon: Icon(Icons.close, size: 16, color: AppColors.white(0.35)),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: 18,
                  color: AppColors.white(0.3),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// プレイリストとお気に入り。1 段だけ潜って中身を出す。
class _LibraryPanel extends StatelessWidget {
  const _LibraryPanel({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    final listing = controller.listing;
    if (listing != null) {
      return _ListingView(controller: controller, listing: listing);
    }
    if (controller.libraryBusy && controller.playlists.isEmpty) {
      return const _Empty(text: '読み込み中…');
    }
    final playlists = controller.playlists;
    final albums = controller.favorites.albums;
    if (playlists.isEmpty && albums.isEmpty) {
      return _Empty(
        text: controller.status == QobuzStatus.connected
            ? 'プレイリストもお気に入りもありません。'
            : '接続中…',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: [
        if (playlists.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: CapsLabel('プレイリスト', size: 10),
          ),
          for (final playlist in playlists)
            _TrackRow(
              title: playlist.name,
              subtitle: '${playlist.tracksCount} 曲',
              imageUrl: playlist.imageUrl,
              onTap: () => controller.openPlaylist(playlist),
              trailing: _AddButton(
                onNext: () => controller.enqueuePlaylist(
                  playlist,
                  option: QobuzQueueOption.next,
                ),
                onAdd: () => controller.enqueuePlaylist(playlist),
              ),
            ),
        ],
        if (albums.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 16, 10, 8),
            child: CapsLabel('お気に入りのアルバム', size: 10),
          ),
          for (final album in albums)
            _TrackRow(
              title: album.title,
              subtitle: album.artist,
              imageUrl: album.imageUrl,
              hires: album.hires,
              onTap: () => controller.openAlbum(album),
              trailing: _AddButton(
                onNext: () => controller.enqueueAlbum(
                  album,
                  option: QobuzQueueOption.next,
                ),
                onAdd: () => controller.enqueueAlbum(album),
              ),
            ),
        ],
      ],
    );
  }
}

/// 開いたプレイリスト / アルバムの中身。
class _ListingView extends StatelessWidget {
  const _ListingView({required this.controller, required this.listing});

  final QobuzController controller;
  final QobuzListing listing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 16, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: controller.closeListing,
                tooltip: '戻る',
                icon: Icon(
                  Icons.arrow_back_rounded,
                  size: 18,
                  color: AppColors.white(0.6),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      listing.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body(15, color: Colors.white),
                    ),
                    if (listing.subtitle != null)
                      Text(
                        listing.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body(12, color: AppColors.white(0.45)),
                      ),
                  ],
                ),
              ),
              TextButton(
                // **並び順はそのまま。** 積んだ順がキューの順になる。
                onPressed: () => controller.enqueueTracks(
                  listing.tracks,
                  label: listing.title,
                ),
                child: Text(
                  'すべて追加',
                  style: AppText.body(13, color: AppColors.white(0.85)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: listing.tracks.isEmpty
              ? const _Empty(text: '曲がありません。')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: listing.tracks.length,
                  itemBuilder: (context, index) {
                    final track = listing.tracks[index];
                    return _TrackRow(
                      title: track.displayTitle,
                      subtitle: track.artist,
                      imageUrl: track.imageUrl,
                      duration: track.duration,
                      hires: track.hiresStreamable,
                      dimmed: !track.streamable,
                      onTap: () => controller.enqueueTrack(track),
                      trailing: _AddButton(
                        onNext: () => controller.enqueueTrack(
                          track,
                          option: QobuzQueueOption.next,
                        ),
                        onAdd: () => controller.enqueueTrack(track),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({required this.controller});

  final QobuzController controller;

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
    final empty = results.isEmpty;

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
              hintText: 'Qobuz を検索',
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
          child: empty
              ? _Empty(
                  text: controller.query.trim().isEmpty
                      ? '曲名・アルバム名・アーティスト名で検索できます。'
                      : (controller.searchBusy ? '検索中…' : '見つかりませんでした。'),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: [
                    if (results.tracks.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(10, 4, 10, 8),
                        child: CapsLabel('曲', size: 10),
                      ),
                      for (final track in results.tracks)
                        _TrackRow(
                          title: track.displayTitle,
                          subtitle: track.artist,
                          imageUrl: track.imageUrl,
                          duration: track.duration,
                          hires: track.hiresStreamable,
                          dimmed: !track.streamable,
                          // タップは「キューの末尾へ」。**みんなで積む**のが
                          // 主目的なので、鳴っているものを止める操作は
                          // 既定にしない。
                          onTap: () => controller.enqueueTrack(track),
                          trailing: _AddButton(
                            onNext: () => controller.enqueueTrack(
                              track,
                              option: QobuzQueueOption.next,
                            ),
                            onAdd: () => controller.enqueueTrack(track),
                          ),
                        ),
                    ],
                    if (results.albums.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(10, 16, 10, 8),
                        child: CapsLabel('アルバム', size: 10),
                      ),
                      for (final album in results.albums)
                        _TrackRow(
                          title: album.title,
                          subtitle: album.artist,
                          imageUrl: album.imageUrl,
                          hires: album.hires,
                          onTap: () => controller.openAlbum(album),
                          trailing: _AddButton(
                            onNext: () => controller.enqueueAlbum(
                              album,
                              option: QobuzQueueOption.next,
                            ),
                            onAdd: () => controller.enqueueAlbum(album),
                          ),
                        ),
                    ],
                    if (results.artists.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(10, 16, 10, 8),
                        child: CapsLabel('アーティスト', size: 10),
                      ),
                      for (final artist in results.artists)
                        _TrackRow(
                          title: artist.name,
                          subtitle: '${artist.albumsCount} 枚',
                          imageUrl: artist.imageUrl,
                          onTap: () => controller.onQueryChanged(artist.name),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// 一覧の 1 行。キュー・ライブラリ・検索で共通。
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.imageUrl,
    this.duration,
    this.hires = false,
    this.dimmed = false,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Duration? duration;
  final bool hires;

  /// 鳴らせない曲。**押せなくはしない**——別バージョンを探す取っ掛かりになる。
  final bool dimmed;

  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final opacity = dimmed ? 0.4 : 1.0;
    return HoverRow(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Opacity(
        opacity: opacity,
        child: Row(
          children: [
            Artwork(url: imageUrl, size: 40, radius: AppRadius.thumbSmall),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body(14, color: Colors.white),
                        ),
                      ),
                      if (hires) ...[
                        const SizedBox(width: 8),
                        const CapsLabel(
                          'HI-RES',
                          size: 9,
                          color: AppColors.green,
                        ),
                      ],
                    ],
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body(12, color: AppColors.white(0.45)),
                    ),
                ],
              ),
            ),
            if (duration != null) ...[
              const SizedBox(width: 10),
              Text(
                formatDuration(duration!),
                style: AppText.grotesk(size: 12, color: AppColors.white(0.35)),
              ),
            ],
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 「次に再生」と「末尾に追加」。
///
/// **2 つとも常に出す。** 壁掛けで人が交代しながら積むので、
/// 長押しやメニューの奥に隠すと使われない。
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onNext, required this.onAdd});

  final VoidCallback onNext;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onNext,
          tooltip: '次に再生',
          icon: Icon(
            Icons.playlist_play_rounded,
            size: 20,
            color: AppColors.white(0.5),
          ),
        ),
        IconButton(
          onPressed: onAdd,
          tooltip: 'キューに追加',
          icon: Icon(
            Icons.playlist_add_rounded,
            size: 20,
            color: AppColors.white(0.5),
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

  final QobuzController controller;

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
