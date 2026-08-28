import 'package:flutter/material.dart';

import '../../models/qobuz_models.dart';
import '../../state/qobuz_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/artwork_backdrop.dart';
import '../widgets/overlays.dart';
import '../widgets/atoms.dart';
import '../widgets/source_layout.dart';
import '../widgets/transport.dart';
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
        return LayoutBuilder(
          builder: (context, constraints) {
            // **骨組みは music の `ControllerScreen` と同じ。** 画面いっぱいに
            // 敷いて（SafeArea を掛けず）、帯のぶんは中身だけ下げる。そうしないと
            // ステータスバーの帯が背景グラデ 1 枚になり、レールの面と境界線が
            // 帯の手前で途切れる。
            final wide = constraints.maxWidth >= kTabletBreakpoint;
            final topPad = MediaQuery.paddingOf(context).top;
            // 帯の下にエラーが出ているぶんも中身を下げる。
            final contentTop =
                topPad + (controller.errorBanner != null ? _bannerHeight : 0);

            return Scaffold(
              backgroundColor: AppColors.frameBg,
              body: ArtworkBackdrop(
                palette: controller.palette,
                stopped: controller.isStopped,
                wide: wide,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: wide
                          ? _TabletBody(
                              controller: controller,
                              topInset: contentTop,
                              menu: _menu(),
                            )
                          : _PhoneBody(
                              controller: controller,
                              topInset: contentTop,
                              menu: _menu(),
                            ),
                    ),
                    if (controller.errorBanner != null)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _ErrorBanner(
                          controller: controller,
                          topPad: topPad,
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
            );
          },
        );
      },
    );
  }

  Widget? _menu() {
    final onOpenMenu = this.onOpenMenu;
    if (onOpenMenu == null) return null;
    return MenuButton(onPressed: onOpenMenu);
  }
}

/// エラーの帯の高さ。**中身を下げる量と一致させる**（music の停止バナーと同型）。
const double _bannerHeight = 52;

/// iPhone。music の `PhoneLayout` と同じ——now playing の上にシートが被さる。
class _PhoneBody extends StatelessWidget {
  const _PhoneBody({
    required this.controller,
    required this.topInset,
    required this.menu,
  });

  final QobuzController controller;
  final double topInset;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    return PhoneSourceScaffold(
      topInset: topInset,
      sheetOpen: controller.sheetOpen,
      nowPlaying: _NowPlaying(
        controller: controller,
        topInset: topInset,
        menu: menu,
      ),
      sheet: SourceSheet(
        open: controller.sheetOpen,
        onToggle: controller.toggleSheet,
        peek: _SheetPeek(controller: controller),
        body: _SheetBody(controller: controller),
      ),
    );
  }
}

/// iPad。music の `TabletLayout` と同じ——左に大判、右に幅 452 のレール。
class _TabletBody extends StatelessWidget {
  const _TabletBody({
    required this.controller,
    required this.topInset,
    required this.menu,
  });

  final QobuzController controller;
  final double topInset;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    return Row(
      children: [
        Expanded(
          child: TabletNowPlaying(
            controller: controller,
            topInset: topInset,
            artworkUrl: track?.imageUrl,
            metaLine:
                _metaLine(track) ??
                (controller.isStopped ? 'LAST PLAYED' : 'NOW PLAYING'),
            title: track?.displayTitle ?? '再生していません',
            header: _HeaderRow(controller: controller, menu: menu),
            // **ハイレゾかどうかはここでしか分からない。** WiiM の画面を見に
            // 行かずに済むよう、メタ行の右端に出す（§3 の落とし穴 6）。
            metaTrailing: track?.qualityLabel == null
                ? null
                : _QualityBadge(track: track!),
          ),
        ),
        SizedBox(
          width: SourceRail.width,
          child: SourceRail(
            controller: controller,
            topInset: topInset,
            onSeek: controller.controlsEnabled ? controller.seek : null,
            transport: _Transport(controller: controller, compact: false),
            tabs: _Tabs(controller: controller),
            panel: _PanelBody(controller: controller),
          ),
        ),
      ],
    );
  }
}

/// 「アーティスト / アルバム」。どちらか欠けたら残ったほうだけ、両方無ければ null。
String? _metaLine(QobuzTrack? track) {
  if (track == null) return null;
  final parts = [
    track.artist ?? '',
    track.albumTitle ?? '',
  ].where((v) => v.trim().isNotEmpty).toList();
  return parts.isEmpty ? null : parts.join(' / ');
}

/// アートワーク・曲名・シークバー・トランスポート（iPhone）。
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({
    required this.controller,
    required this.topInset,
    required this.menu,
  });

  final QobuzController controller;
  final double topInset;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    return PhoneNowPlaying(
      controller: controller,
      topInset: topInset,
      statusLabel: _statusLabel(controller),
      artworkUrl: track?.imageUrl,
      title: track?.displayTitle ?? '再生していません',
      subtitle: track?.artist ?? '',
      header: _HeaderRow(controller: controller, menu: menu),
      belowSubtitle: track?.qualityLabel == null
          ? null
          : _QualityBadge(track: track!),
      // **Qobuz は頭出しできる。** WiiM に直接投げているので、Spotify Connect
      // のように機器がシークを拒むことがない。
      onSeek: controller.controlsEnabled ? controller.seek : null,
      transport: _Transport(controller: controller, compact: true),
    );
  }
}

/// アートワークの上の 1 行。music の `PlayerController.statusLabel` と同じ役。
String _statusLabel(QobuzController controller) => switch (controller.status) {
  QobuzStatus.connected =>
    controller.isPlaying ? 'PLAYING ON WIIM' : 'PAUSED ON WIIM',
  QobuzStatus.connecting => 'CONNECTING',
  QobuzStatus.offline => 'WIIM OFFLINE',
  _ => 'NOT CONNECTED',
};

/// 閉じているときの 1 行プレビュー。music の `_SheetPeek` と同じ体裁。
class _SheetPeek extends StatelessWidget {
  const _SheetPeek({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    final next = controller.nextTrack;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.toggleSheet,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        child: Row(
          children: [
            Artwork(
              url: next?.imageUrl,
              size: 46,
              radius: const BorderRadius.all(Radius.circular(5)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  CapsLabel(
                    'Next up',
                    size: 10,
                    color: controller.palette.accent,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    next?.displayTitle ?? 'キューは空です',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body(16, weight: FontWeight.w900),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '+${controller.upNext.length}',
              style: AppText.body(12, color: AppColors.white(0.4)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 開いたときの中身（タブ + パネル）。music の `_SheetBody` と同じ余白。
class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
          child: _Tabs(controller: controller),
        ),
        Expanded(
          child: Padding(
            // ボトムシートは画面下端に接するので、ホームインジケータぶんを足す。
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              18,
              18 + MediaQuery.paddingOf(context).bottom,
            ),
            child: _PanelBody(controller: controller),
          ),
        ),
      ],
    );
  }
}

/// キュー / ライブラリ / 検索。**見た目は music の `RailTabs` と同じ部品。**
class _Tabs extends StatelessWidget {
  const _Tabs({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    final upNext = controller.upNext.length;
    return SegmentedTabs(
      tabs: [
        TabButton(
          label: upNext == 0 ? 'Up next' : 'Up next ($upNext)',
          active: controller.tab == QobuzTab.queue,
          onTap: () => controller.selectTab(QobuzTab.queue),
        ),
        TabButton(
          label: 'Library',
          active: controller.tab == QobuzTab.library,
          onTap: () => controller.selectTab(QobuzTab.library),
        ),
        TabButton(
          label: 'Search',
          active: controller.tab == QobuzTab.search,
          onTap: () => controller.selectTab(QobuzTab.search),
        ),
      ],
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) => switch (controller.tab) {
    QobuzTab.queue => _QueueList(controller: controller),
    QobuzTab.library => _LibraryPanel(controller: controller),
    QobuzTab.search => _SearchPanel(controller: controller),
  };
}

/// ☰ / モード名 / WiiM のピル（タップで音量）。
/// ☰ / WiiM のピル（タップで音量）/ 音源名。
///
/// **並びは music の見出しの行と同じ。** 左に ☰、その隣に出力先のピル、
/// 右端に音源名（music 側は SPOTIFY CONNECT）。壁掛けで人が入れ替わりながら
/// 触るので、いま何を操作しているかは常に同じ位置に出す。
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.controller, this.menu});

  final QobuzController controller;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    return Row(
        children: [
          if (menu != null) ...[menu!, const SizedBox(width: MenuButton.gap)],
          Flexible(
            child: GlassPill(
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
                // **名前が長いと溢れる。** 狭い端末では省略に倒す
                // （music のデバイスピルと同じ扱い）。
                Flexible(
                  child: CapCentered(
                    fontSize: 13,
                    child: Text(
                      controller.status == QobuzStatus.connected
                          ? controller.deviceName
                          : _statusText(controller.status),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body(13, color: AppColors.white(0.8)),
                    ),
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
          ),
          const Spacer(),
          const CapsLabel('QOBUZ'),
        ],
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

/// 画面の一番上に出る帯。
///
/// **自前でステータスバーぶんまで塗る**（music の停止バナーと同型）。
/// 帯が出ている間はそのぶん中身を下げるので、高さは [_bannerHeight] と
/// 揃えること。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.controller, required this.topPad});

  final QobuzController controller;
  final double topPad;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, topPad + 6, 8, 6),
      height: topPad + _bannerHeight,
      color: AppColors.danger.withValues(alpha: 0.18),
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
///
/// **並びも寸法も music（`PhoneLayout._NowPlaying`）に合わせてある。**
/// 音源が変わっても手が同じ場所を探せるように、アートワークの演出
/// （[SwipeSkip] / [OrbitingLight]）とシークバー・トランスポートは
/// music と同じ部品を使う。Qobuz にしか無いのは音質バッジだけ。
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

/// シャッフル / ◀◀・再生・▶▶ / リピート。
///
/// **真ん中の 3 つは music と同じ部品**（[TransportControls]）。寸法も見た目も
/// あちらに揃うので、音源を切り替えても押す場所が変わらない。左右のシャッフルと
/// リピートは Qobuz 側にしか無い（キューを持っているのがこのアプリだから）。
class _Transport extends StatelessWidget {
  const _Transport({required this.controller, required this.compact});

  final QobuzController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.controlsEnabled;
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
        TransportControls(controller: controller, compact: compact),
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
