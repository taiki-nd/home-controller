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

/// iPad 横（デザインは 1194x834）。
/// 左に大判アートワーク、右に幅 452 の常設レール。
///
/// 画面いっぱいに敷く（呼ぶ側で SafeArea を掛けない）。そうしないと
/// ステータスバーの帯が背景グラデ 1 枚になり、レールの面と境界線が帯の
/// 手前で途切れて、時刻・バッテリーの行だけ左右がつながって見える。
/// 帯のぶんは [topInset] で中身だけ下げる。
class TabletLayout extends StatelessWidget {
  const TabletLayout({
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

  /// ステータスバー + 停止バナーぶん、中身を押し下げる。面の塗りは下げない。
  final double topInset;

  /// デバイスピルの点の x（左余白 40 + ピルの左パディング 16）。
  /// ポップオーバーの点をこの列に載せるので、余白を触ったらここも直す。
  static const devicePillDotX = 56.0;

  /// ☰ を出すとピルがそのぶん右へずれる。
  static double devicePillDotXFor({required bool hasMenu}) =>
      hasMenu ? devicePillDotX + MenuButton.shift : devicePillDotX;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _NowPlayingPane(
            controller: controller,
            attribution: attribution,
            menu: menu,
            topInset: topInset,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
          ),
        ),
        SizedBox(
          width: SourceRail.width,
          child: _Rail(
            controller: controller,
            newReleases: newReleases,
            onPlayNow: onPlayNow,
            onPlayPlaylist: onPlayPlaylist,
            onPlayRelease: onPlayRelease,
            topInset: topInset,
          ),
        ),
      ],
    );
  }
}

class _NowPlayingPane extends StatelessWidget {
  const _NowPlayingPane({
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
    return TabletNowPlaying(
      controller: controller,
      topInset: topInset,
      artworkUrl: track?.artworkUrl,
      // アーティスト / アルバムは「Now playing」と同じ体裁の 1 行。
      // 曲がないときだけ、そこに状態を出す。
      metaLine:
          _metaLine(track) ??
          (controller.isStopped ? 'LAST PLAYED' : 'NOW PLAYING'),
      title: track?.name ?? '再生していません',
      header: Row(
        children: [
          if (menu != null) ...[menu!, const SizedBox(width: MenuButton.gap)],
          _DevicePill(controller: controller),
          const Spacer(),
          attribution,
        ],
      ),
      metaTrailing: track == null
          ? null
          : PlaylistToggleButton(
              controller: controller,
              compact: false,
              onRemove: onRemoveFromPlaylist,
            ),
    );
  }
}

/// 「アーティスト / アルバム」。どちらか欠けたら残ったほうだけ、両方無ければ null。
String? _metaLine(Track? track) {
  if (track == null) return null;
  final parts = [
    track.artists,
    track.albumName,
  ].where((v) => v.trim().isNotEmpty).toList();
  return parts.isEmpty ? null : parts.join(' / ');
}

class _DevicePill extends StatelessWidget {
  const _DevicePill({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return GlassPill(
      onTap: controller.toggleDevicePopover,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: controller.deviceDotColor,
            pulse: controller.isPlaying,
          ),
          const SizedBox(width: 10),
          CapCentered(
            fontSize: 14,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                controller.deviceLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(14, weight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.controller,
    required this.newReleases,
    required this.onPlayNow,
    required this.onPlayPlaylist,
    required this.onPlayRelease,
    required this.topInset,
  });

  final PlayerController controller;
  final NewReleasesController newReleases;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;
  final ValueChanged<NewRelease> onPlayRelease;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    return SourceRail(
      controller: controller,
      topInset: topInset,
      transport: TransportControls(controller: controller, compact: false),
      tabs: RailTabs(
        selected: controller.tab,
        onSelect: controller.selectTab,
      ),
      panel: switch (controller.tab) {
        RailTab.queue => QueuePanel(controller: controller, compact: false),
        RailTab.search => SearchPanel(
          controller: controller,
          compact: false,
          onPlayNow: onPlayNow,
        ),
        RailTab.playlists => PlaylistsPanel(
          controller: controller,
          compact: false,
          onPlay: onPlayPlaylist,
        ),
        RailTab.newReleases => NewReleasesPanel(
          controller: newReleases,
          compact: false,
          onPlay: onPlayRelease,
        ),
      },
    );
  }
}
