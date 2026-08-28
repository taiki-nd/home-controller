import 'package:flutter/material.dart';

import '../models/release_models.dart';
import '../models/spotify_models.dart';
import '../state/new_releases_controller.dart';
import '../state/player_controller.dart';
import '../theme/tokens.dart';
import 'widgets/atoms.dart';
import 'widgets/new_releases_panel.dart';
import 'widgets/panels.dart';
import 'widgets/playlist_button.dart';
import 'widgets/source_layout.dart';
import 'widgets/transport.dart';

/// スマホ（デザインは 390x844）。
/// キューと検索はボトムシート。閉じているときは NEXT UP の 1 行だけ見せる。
class PhoneLayout extends StatelessWidget {
  const PhoneLayout({
    super.key,
    required this.controller,
    required this.newReleases,
    required this.onPlayNow,
    required this.onPlayPlaylist,
    required this.onPlayRelease,
    required this.onRemoveFromPlaylist,
    required this.attribution,
    required this.topInset,
    this.menu,
  });

  final PlayerController controller;
  final NewReleasesController newReleases;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;
  final ValueChanged<NewRelease> onPlayRelease;

  /// 再生中の曲をプレイリストから外す（確認ダイアログは呼ぶ側）。
  final PlaylistRemoveRequest onRemoveFromPlaylist;

  final Widget attribution;

  /// デバイスピルの左に置く ☰。行は増やさない。null なら出さない。
  final Widget? menu;

  /// ステータスバー + 停止バナーぶん、コンテンツを押し下げる。
  /// 呼ぶ側が SafeArea を掛けないので、上の余白はここで確保する。
  final double topInset;

  /// デバイスピルの点の x（左余白 24 + ピルの左パディング 14）。
  /// ポップオーバーの点をこの列に載せるので、余白を触ったらここも直す。
  static const devicePillDotX = 38.0;

  /// ☰ を出すとピルがそのぶん右へずれる。
  static double devicePillDotXFor({required bool hasMenu}) =>
      hasMenu ? devicePillDotX + MenuButton.shift : devicePillDotX;

  @override
  Widget build(BuildContext context) {
    return PhoneSourceScaffold(
      topInset: topInset,
      sheetOpen: controller.sheetOpen,
      nowPlaying: _NowPlaying(
        controller: controller,
        attribution: attribution,
        menu: menu,
        topInset: topInset,
        onRemoveFromPlaylist: onRemoveFromPlaylist,
      ),
      sheet: SourceSheet(
        open: controller.sheetOpen,
        onToggle: controller.toggleSheet,
        peek: _SheetPeek(controller: controller),
        body: _SheetBody(
          controller: controller,
          newReleases: newReleases,
          onPlayNow: onPlayNow,
          onPlayPlaylist: onPlayPlaylist,
          onPlayRelease: onPlayRelease,
        ),
      ),
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({
    required this.controller,
    required this.attribution,
    required this.topInset,
    required this.menu,
    required this.onRemoveFromPlaylist,
  });

  final PlayerController controller;
  final Widget attribution;
  final Widget? menu;
  final double topInset;
  final PlaylistRemoveRequest onRemoveFromPlaylist;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    return PhoneNowPlaying(
      controller: controller,
      topInset: topInset,
      statusLabel: controller.statusLabel,
      artworkUrl: track?.artworkUrl,
      title: track?.name ?? '再生していません',
      subtitle: track?.artists ?? '',
      header: Row(
        children: [
          if (menu != null) ...[menu!, const SizedBox(width: MenuButton.gap)],
          Flexible(child: _DevicePill(controller: controller)),
          const Spacer(),
          attribution,
        ],
      ),
      // 停止中はボタン自体が消える（幅は曲名が使う）。
      titleTrailing: track == null
          ? null
          : PlaylistToggleButton(
              controller: controller,
              compact: true,
              onRemove: onRemoveFromPlaylist,
            ),
      transport: TransportControls(controller: controller, compact: true),
    );
  }
}

class _DevicePill extends StatelessWidget {
  const _DevicePill({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return GlassPill(
      onTap: controller.toggleDevicePopover,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: controller.deviceDotColor,
            size: 7,
            pulse: controller.isPlaying,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: CapCentered(
              fontSize: 13,
              child: Text(
                controller.deviceLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(13, weight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 閉じているときの 1 行プレビュー。
class _SheetPeek extends StatelessWidget {
  const _SheetPeek({required this.controller});

  final PlayerController controller;

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
              url: next?.smallArtworkUrl,
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
                    next?.name ?? 'キューは空です',
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

class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.controller,
    required this.newReleases,
    required this.onPlayNow,
    required this.onPlayPlaylist,
    required this.onPlayRelease,
  });

  final PlayerController controller;
  final NewReleasesController newReleases;
  final ValueChanged<NewRelease> onPlayRelease;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
          child: RailTabs(
            selected: controller.tab,
            onSelect: controller.selectTab,
            // 4 タブぶんの幅しかないので、スマホだけ短くする。
            labels: const {
              RailTab.search: 'Add',
              RailTab.playlists: 'Lists',
            },
          ),
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
            child: switch (controller.tab) {
              RailTab.queue => QueuePanel(controller: controller, compact: true),
              RailTab.search => SearchPanel(
                controller: controller,
                compact: true,
                onPlayNow: onPlayNow,
              ),
              RailTab.playlists => PlaylistsPanel(
                controller: controller,
                compact: true,
                onPlay: onPlayPlaylist,
              ),
              RailTab.newReleases => NewReleasesPanel(
                controller: newReleases,
                compact: true,
                onPlay: onPlayRelease,
              ),
            },
          ),
        ),
      ],
    );
  }
}
