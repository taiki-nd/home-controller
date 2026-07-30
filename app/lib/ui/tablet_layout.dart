import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/spotify_models.dart';
import '../state/player_controller.dart';
import '../theme/tokens.dart';
import 'widgets/atoms.dart';
import 'widgets/marquee_text.dart';
import 'widgets/orbiting_light.dart';
import 'widgets/panels.dart';
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
    required this.onPlayNow,
    required this.onPlayPlaylist,
    required this.attribution,
    required this.topInset,
  });

  final PlayerController controller;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;
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
            onPlayNow: onPlayNow,
            onPlayPlaylist: onPlayPlaylist,
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
        // デザインは 500px（停止中 430px）。狭い iPad でも収まるよう上限を掛ける。
        // 高さは中身が使える分（= 全高 - topInset）で測る。
        final artSize = (stopped ? 430.0 : 500.0).clamp(
          200.0,
          (constraints.maxHeight - topInset - 320).clamp(200.0, 520.0),
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
              CapsLabel(
                stopped ? 'Last played' : 'Now playing',
                size: 12,
                color: AppColors.white(0.55),
              ),
              const SizedBox(height: 10),
              // 3 行ぶんの高さが曲によらず一定になるので、上の Expanded の取り分＝
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
              const SizedBox(height: 8),
              MarqueeText(
                track?.artists ?? '',
                style: AppText.body(
                  24,
                  weight: FontWeight.w700,
                  color: AppColors.white(0.72),
                ),
              ),
              const SizedBox(height: 6),
              MarqueeText(
                track?.albumName ?? '',
                style: AppText.body(15, color: AppColors.white(0.42)),
              ),
            ],
          ),
        );
      },
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
    required this.onPlayNow,
    required this.onPlayPlaylist,
    required this.topInset,
  });

  final PlayerController controller;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;

  /// 面はここも含めて塗り、進捗バーだけこのぶん下げる。
  /// ステータスバーの帯をレールの色で塗り分けているのがこれ。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.bg.withValues(alpha: 0.72),
            border: Border(left: BorderSide(color: AppColors.white(0.08))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, 14),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.white(0.08)),
                  ),
                ),
                child: Column(
                  children: [
                    ProgressRow(controller: controller),
                    const SizedBox(height: 12),
                    TransportControls(controller: controller, compact: false),
                  ],
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
