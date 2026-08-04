import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/release_models.dart';
import '../models/spotify_models.dart';
import '../state/new_releases_controller.dart';
import '../state/player_controller.dart';
import '../theme/tokens.dart';
import 'widgets/atoms.dart';
import 'widgets/marquee_text.dart';
import 'widgets/new_releases_panel.dart';
import 'widgets/orbiting_light.dart';
import 'widgets/panels.dart';
import 'widgets/soft_surface.dart';
import 'widgets/swipe_skip.dart';
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
    required this.attribution,
    required this.topInset,
  });

  final PlayerController controller;
  final NewReleasesController newReleases;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;
  final ValueChanged<NewRelease> onPlayRelease;
  final Widget attribution;

  /// ステータスバー + 停止バナーぶん、中身を押し下げる。面の塗りは下げない。
  final double topInset;

  /// デバイスピルの点の x（左余白 40 + ピルの左パディング 16）。
  /// ポップオーバーの点をこの列に載せるので、余白を触ったらここも直す。
  static const devicePillDotX = 56.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _NowPlayingPane(
            controller: controller,
            attribution: attribution,
            topInset: topInset,
          ),
        ),
        SizedBox(
          width: 452,
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
  });

  final PlayerController controller;
  final Widget attribution;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    final stopped = controller.isStopped;

    return LayoutBuilder(
      builder: (context, constraints) {
        // デザインは 570px（停止中 490px）。狭い iPad でも収まるよう上限を掛ける。
        // 高さは中身が使える分（= 全高 - topInset）で測る。
        // 引く 250 は、上のデバイスピル行と下の 2 行ぶんの取り分。
        final artSize = (stopped ? 490.0 : 570.0).clamp(
          200.0,
          (constraints.maxHeight - topInset - 250).clamp(200.0, 600.0),
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(40, topInset + 34, 30, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _DevicePill(controller: controller),
                  const Spacer(),
                  attribution,
                ],
              ),
              Expanded(
                child: Center(
                  child: SwipeSkip(
                    size: artSize.toDouble(),
                    enabled: !controller.deviceLost,
                    onNext: controller.skipNext,
                    onPrevious: controller.skipPrevious,
                    child: OrbitingLight(
                      size: artSize.toDouble(),
                      active: controller.isPlaying,
                      tint: Color.lerp(
                        controller.palette.accent,
                        Colors.white,
                        0.45,
                      )!,
                      child: Artwork(
                        url: track?.artworkUrl,
                        size: artSize.toDouble(),
                        opacity: stopped ? 0.4 : 1.0,
                        placeholderColors: [
                          controller.palette.deep,
                          controller.palette.accent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // アーティスト / アルバムは「Now playing」と同じ体裁の 1 行。
              // 曲がないときだけ、そこに状態を出す。
              MarqueeText(
                _metaLine(track) ?? (stopped ? 'LAST PLAYED' : 'NOW PLAYING'),
                style: AppText.caps(12, AppColors.white(0.55)),
              ),
              const SizedBox(height: 10),
              // 2 行ぶんの高さが曲によらず一定になるので、上の Expanded の取り分＝
              // アートワークの位置も動かない。
              MarqueeText(
                track?.name ?? '再生していません',
                style: AppText.body(
                  50,
                  weight: FontWeight.w900,
                  height: 1.04,
                  letterSpacing: -1.5,
                ),
              ),
            ],
          ),
        );
      },
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

  /// 面はここも含めて塗り、進捗バーだけこのぶん下げる。
  /// ステータスバーの帯をレールの色で塗り分けているのがこれ。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        // 左端は線で仕切らず、レールの色そのものを左の面へ繋ぐ。
        child: SoftSurface(
          color: AppColors.bg.withValues(alpha: 0.72),
          edges: const [AxisDirection.left],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 進捗＋トランスポートの段。ここも線ではなく、わずかに持ち上げた
              // 面が下（キュー側）とレールの左へ溶けていく形で仕切る。
              // 下の余白 15 = 元の 14 + 線 1px ぶん。中身の位置は動かない。
              SoftSurface(
                color: AppColors.surface.withValues(alpha: 0.55),
                edges: const [AxisDirection.down, AxisDirection.left],
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, 15),
                  child: Column(
                    children: [
                      ProgressRow(controller: controller),
                      const SizedBox(height: 12),
                      TransportControls(controller: controller, compact: false),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
                child: RailTabs(
                  selected: controller.tab,
                  onSelect: controller.selectTab,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  child: switch (controller.tab) {
                    RailTab.queue =>
                      QueuePanel(controller: controller, compact: false),
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
