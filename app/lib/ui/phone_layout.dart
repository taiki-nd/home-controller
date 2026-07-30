import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/spotify_models.dart';
import '../state/player_controller.dart';
import '../theme/tokens.dart';
import 'widgets/atoms.dart';
import 'widgets/marquee_text.dart';
import 'widgets/panels.dart';
import 'widgets/swipe_skip.dart';
import 'widgets/transport.dart';

/// スマホ（デザインは 390x844）。
/// キューと検索はボトムシート。閉じているときは NEXT UP の 1 行だけ見せる。
class PhoneLayout extends StatelessWidget {
  const PhoneLayout({
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

  /// 停止バナーの高さぶん、コンテンツを押し下げる。
  final double topInset;

  static const _sheetClosedHeight = 116.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sheetHeight = controller.sheetOpen
            ? constraints.maxHeight * 0.78
            : _sheetClosedHeight;

        return Stack(
          children: [
            Positioned.fill(
              bottom: _sheetClosedHeight,
              child: _NowPlaying(
                controller: controller,
                attribution: attribution,
                topInset: topInset,
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              left: 0,
              right: 0,
              bottom: 0,
              height: sheetHeight,
              child: _Sheet(
                controller: controller,
                onPlayNow: onPlayNow,
                onPlayPlaylist: onPlayPlaylist,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({
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
        // デザインは 342px（停止中 250px）。小さい端末では縮める。
        final artSize = (stopped ? 250.0 : 342.0).clamp(
          140.0,
          (constraints.maxWidth - 48).clamp(140.0, 342.0),
        );

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, topInset + 16, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Flexible(child: _DevicePill(controller: controller)),
                  const Spacer(),
                  attribution,
                ],
              ),
              const SizedBox(height: 12),
              Text(
                controller.statusLabel,
                style: AppText.grotesk(
                  size: 11,
                  color: AppColors.white(0.4),
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 22),
              Center(
                child: SwipeSkip(
                  size: artSize.toDouble(),
                  enabled: !controller.deviceLost,
                  onNext: controller.skipNext,
                  onPrevious: controller.skipPrevious,
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
                        color: Colors.black.withValues(alpha: 0.85),
                        blurRadius: 70,
                        spreadRadius: -24,
                        offset: const Offset(0, 36),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              MarqueeText(
                track?.name ?? '再生していません',
                style: AppText.body(
                  30,
                  weight: FontWeight.w900,
                  height: 1.08,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 6),
              MarqueeText(
                track?.artists ?? '',
                style: AppText.body(
                  18,
                  weight: FontWeight.w700,
                  color: AppColors.white(0.68),
                ),
              ),
              const SizedBox(height: 20),
              ProgressRow(controller: controller, barHeight: 5, labelSize: 12),
              const SizedBox(height: 18),
              TransportControls(controller: controller, compact: true),
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
            child: Text(
              controller.deviceLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.body(13, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.controller,
    required this.onPlayNow,
    required this.onPlayPlaylist,
  });

  final PlayerController controller;
  final ValueChanged<Track> onPlayNow;
  final ValueChanged<PlaylistSummary> onPlayPlaylist;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0C0C0E).withValues(alpha: 0.94),
            border: Border(top: BorderSide(color: AppColors.white(0.12))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // グラブハンドル。上下スワイプでも開閉できるようにしておく。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: controller.toggleSheet,
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -120 && !controller.sheetOpen) {
                    controller.toggleSheet();
                  } else if (velocity > 120 && controller.sheetOpen) {
                    controller.toggleSheet();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        color: AppColors.white(0.28),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: controller.sheetOpen
                    ? _SheetBody(
                        controller: controller,
                        onPlayNow: onPlayNow,
                        onPlayPlaylist: onPlayPlaylist,
                      )
                    : _SheetPeek(controller: controller),
              ),
            ],
          ),
        ),
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
    required this.onPlayNow,
    required this.onPlayPlaylist,
  });

  final PlayerController controller;
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
            labels: const ['Up next', 'Add tracks', 'Lists'],
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
            },
          ),
        ),
      ],
    );
  }
}
