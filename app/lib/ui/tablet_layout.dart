import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/spotify_models.dart';
import '../state/player_controller.dart';
import '../theme/tokens.dart';
import 'widgets/atoms.dart';
import 'widgets/panels.dart';
import 'widgets/transport.dart';

/// iPad 横（デザインは 1194x834）。
/// 左に大判アートワーク、右に幅 452 の常設レール。
class TabletLayout extends StatelessWidget {
  const TabletLayout({
    super.key,
    required this.controller,
    required this.onPlayNow,
    required this.onPlayPlaylist,
    required this.attribution,
  });

  final PlayerController controller;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;
  final Widget attribution;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _NowPlayingPane(controller: controller, attribution: attribution)),
        SizedBox(
          width: 452,
          child: _Rail(
            controller: controller,
            onPlayNow: onPlayNow,
            onPlayPlaylist: onPlayPlaylist,
          ),
        ),
      ],
    );
  }
}

class _NowPlayingPane extends StatelessWidget {
  const _NowPlayingPane({required this.controller, required this.attribution});

  final PlayerController controller;
  final Widget attribution;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    final stopped = controller.isStopped;

    return LayoutBuilder(
      builder: (context, constraints) {
        // デザインは 500px（停止中 430px）。狭い iPad でも収まるよう上限を掛ける。
        final artSize = (stopped ? 430.0 : 500.0).clamp(
          200.0,
          (constraints.maxHeight - 320).clamp(200.0, 520.0),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(40, 34, 30, 30),
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
                  child: Artwork(
                    url: track?.artworkUrl,
                    size: artSize.toDouble(),
                    opacity: stopped ? 0.4 : 1.0,
                    placeholderColors: [
                      controller.palette.deep,
                      controller.palette.accent,
                    ],
                    shadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.9),
                        blurRadius: 100,
                        spreadRadius: -28,
                        offset: const Offset(0, 50),
                      ),
                    ],
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
              Text(
                track?.name ?? '再生していません',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(
                  50,
                  weight: FontWeight.w900,
                  height: 1.04,
                  letterSpacing: -1.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                track?.artists ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(
                  24,
                  weight: FontWeight.w700,
                  color: AppColors.white(0.72),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                track?.albumName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              controller.deviceLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.body(14, weight: FontWeight.w700),
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
  });

  final PlayerController controller;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;

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
                padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.white(0.08)),
                  ),
                ),
                child: Column(
                  children: [
                    ProgressRow(controller: controller),
                    const SizedBox(height: 16),
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
