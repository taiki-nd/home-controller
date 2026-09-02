import 'dart:ui';

import 'package:flutter/material.dart';

import '../../state/playback_surface.dart';
import '../../theme/tokens.dart';
import 'atoms.dart';
import 'marquee_text.dart';
import 'orbiting_light.dart';
import 'soft_surface.dart';
import 'swipe_skip.dart';
import 'transport.dart';

/// 再生画面の器。**音源が変わっても寸法も余白も 1 か所から出す。**
///
/// Spotify（`PhoneLayout` / `TabletLayout`）と Qobuz（`QobuzView`）で、
/// 見た目を「似せる」のではなく**同じ木を組む**ためにここへ集めた。以前は
/// それぞれが自前で Column を積んでいたので、片方だけ余白が違う・シートが
/// 無い、といったズレが必ず出た。
///
/// **音源ごとの違いは差し込み口（スロット）で受ける。** Spotify のデバイス
/// ピルやプレイリストのボタン、Qobuz の音質バッジやシャッフル・リピートは、
/// ここには持ち込まず呼ぶ側が widget で渡す。

/// スマホの now playing（画面いっぱい、下にシートが被さる）。
///
/// 並びは上から: 見出しの行 → 状態の 1 行 → アートワーク → 曲名 →
/// アーティスト → （任意の 1 段）→ シークバー → トランスポート。
class PhoneNowPlaying extends StatelessWidget {
  const PhoneNowPlaying({
    super.key,
    required this.controller,
    required this.topInset,
    required this.header,
    required this.statusLabel,
    required this.artworkUrl,
    required this.title,
    required this.subtitle,
    required this.transport,
    this.titleTrailing,
    this.belowSubtitle,
    this.onSeek,
  });

  final PlaybackSurface controller;

  /// ステータスバー + 停止バナーぶん。呼ぶ側が SafeArea を掛けない前提。
  final double topInset;

  /// ☰ とピルの行。音源ごとに中身が違うのでまるごと受ける。
  final Widget header;

  /// アートワークの上の 1 行（Spotify は再生状態、Qobuz は接続先）。
  final String statusLabel;

  final String? artworkUrl;
  final String title;
  final String subtitle;

  /// 曲名の右。**行は増やさない**（Spotify のプレイリストのボタン）。
  final Widget? titleTrailing;

  /// アーティストの下（Qobuz の音質バッジ）。
  final Widget? belowSubtitle;

  /// ◀◀ / 再生 / ▶▶ の段。Qobuz はここにシャッフルとリピートも並ぶ。
  final Widget transport;

  final ValueChanged<Duration>? onSeek;

  @override
  Widget build(BuildContext context) {
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
              header,
              const SizedBox(height: 12),
              Text(
                statusLabel,
                style: AppText.grotesk(
                  size: 11,
                  color: AppColors.white(0.4),
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 22),
              Center(
                child: SourceArtwork(
                  controller: controller,
                  url: artworkUrl,
                  size: artSize.toDouble(),
                ),
              ),
              const SizedBox(height: 24),
              // 曲名の右に 1 つだけ差せる。行は増やさない。
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: MarqueeText(
                      title,
                      style: AppText.body(
                        30,
                        weight: FontWeight.w900,
                        height: 1.08,
                        letterSpacing: -0.6,
                      ),
                    ),
                  ),
                  if (titleTrailing != null) ...[
                    const SizedBox(width: 12),
                    titleTrailing!,
                  ],
                ],
              ),
              const SizedBox(height: 6),
              MarqueeText(
                subtitle,
                style: AppText.body(
                  18,
                  weight: FontWeight.w700,
                  color: AppColors.white(0.68),
                ),
              ),
              if (belowSubtitle != null) ...[
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: belowSubtitle!),
              ],
              const SizedBox(height: 20),
              ProgressRow(
                controller: controller,
                barHeight: 5,
                labelSize: 12,
                onSeek: onSeek,
              ),
              const SizedBox(height: 18),
              transport,
            ],
          ),
        );
      },
    );
  }
}

/// iPad の左半分。大判アートワークと特大の曲名 + メタ 1 行。
class TabletNowPlaying extends StatelessWidget {
  const TabletNowPlaying({
    super.key,
    required this.controller,
    required this.topInset,
    required this.header,
    required this.artworkUrl,
    required this.metaLine,
    required this.title,
    this.metaTrailing,
  });

  final PlaybackSurface controller;
  final double topInset;
  final Widget header;
  final String? artworkUrl;

  /// 「アーティスト / アルバム」。曲が無いときは呼ぶ側が状態を入れる。
  final String metaLine;

  final String title;

  /// メタ行の右端。**行は増やさない。**
  final Widget? metaTrailing;

  @override
  Widget build(BuildContext context) {
    final stopped = controller.isStopped;

    return LayoutBuilder(
      builder: (context, constraints) {
        // デザインは 570px（停止中 490px）。狭い iPad でも収まるよう上限を掛ける。
        // 高さは中身が使える分（= 全高 - topInset）で測る。
        // 引く 280 は、上のピルの行と下の 2 行ぶんの取り分。メタ行には高さ 44 の
        // ボタンが入りうるので、文字だけの行より背が高い。ここを詰めると
        // 狭い iPad で Column が溢れる。
        final artSize = (stopped ? 490.0 : 570.0).clamp(
          200.0,
          (constraints.maxHeight - topInset - 280).clamp(200.0, 600.0),
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(40, topInset + 34, 30, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: Center(
                  child: SourceArtwork(
                    controller: controller,
                    url: artworkUrl,
                    size: artSize.toDouble(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // 2 行ぶんの高さが曲によらず一定になるので、上の Expanded の
              // 取り分＝アートワークの位置も動かない。
              MarqueeText(
                title,
                style: AppText.body(
                  50,
                  weight: FontWeight.w900,
                  height: 1.04,
                  letterSpacing: -1.5,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: MarqueeText(
                      metaLine,
                      style: AppText.caps(12, AppColors.white(0.55)),
                    ),
                  ),
                  if (metaTrailing != null) ...[
                    const SizedBox(width: 16),
                    metaTrailing!,
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// アートワーク + 左右に払って曲送り + 再生中に回る光。**3 つで 1 組。**
/// 片方の音源だけ演出が無い、という状態を作らないためにまとめてある。
class SourceArtwork extends StatelessWidget {
  const SourceArtwork({
    super.key,
    required this.controller,
    required this.url,
    required this.size,
  });

  final PlaybackSurface controller;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SwipeSkip(
      size: size,
      enabled: controller.controlsEnabled,
      onNext: controller.skipNext,
      onPrevious: controller.skipPrevious,
      child: OrbitingLight(
        size: size,
        active: controller.isPlaying,
        tint: Color.lerp(controller.palette.accent, Colors.white, 0.45)!,
        child: Artwork(
          url: url,
          size: size,
          opacity: controller.isStopped ? 0.4 : 1.0,
          placeholderColors: [
            controller.palette.deep,
            controller.palette.accent,
          ],
        ),
      ),
    );
  }
}

/// iPad の右レール（幅は呼ぶ側が決める）。
///
/// 上から: タブ → パネル → 進捗＋トランスポートの段。操作はいちばん下、
/// 親指の届くところにまとめる。段の仕切りは線ではなく、わずかに持ち上げた面が
/// 上へ溶けていく形。
///
/// レールの左端は溶かさない。左ペインのグラデがそこで一度途切れて見えるので、
/// 面はまっすぐ切る（要望どおり。壁掛けの焼きつきについては下の注記）。
class SourceRail extends StatelessWidget {
  const SourceRail({
    super.key,
    required this.controller,
    required this.topInset,
    required this.tabs,
    required this.panel,
    required this.transport,
    this.onSeek,
  });

  final PlaybackSurface controller;

  /// 面はここも含めて塗り、進捗バーだけこのぶん下げる。
  /// ステータスバーの帯をレールの色で塗り分けているのがこれ。
  final double topInset;

  final Widget tabs;
  final Widget panel;
  final Widget transport;
  final ValueChanged<Duration>? onSeek;

  /// レールの幅。デザインは 452。
  static const width = 452.0;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        // 左端はまっすぐ切る。ここを溶かすと、左ペインのグラデがレールの手前で
        // 一段暗くなってから面に変わるので、境目が「にじんだ帯」として見える。
        //
        // 焼きつき対策はこの辺を動かすことで効かせていたが、境目にあるのは
        // 1px の線ではなく幅 452 の面の縁なので、面の内側（段の仕切り）だけ
        // 溶かしておけば、輝度一定の細い線は画面に残らない。
        child: ColoredBox(
          color: AppColors.bg.withValues(alpha: 0.72),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, 14),
                child: tabs,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: panel,
                ),
              ),
              // 操作の段。上の余白 15 = 元の 14 + 線 1px ぶん。
              // 下はホームインジケータのぶんを足す（レールは画面下端に接する）。
              SoftSurface(
                color: AppColors.surface.withValues(alpha: 0.55),
                edges: const [AxisDirection.up],
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    15,
                    24,
                    20 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Column(
                    children: [
                      ProgressRow(controller: controller, onSeek: onSeek),
                      const SizedBox(height: 12),
                      transport,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// スマホのボトムシート。閉じているときは 1 行だけ見せる。
class SourceSheet extends StatelessWidget {
  const SourceSheet({
    super.key,
    required this.open,
    required this.onToggle,
    required this.peek,
    required this.body,
  });

  final bool open;
  final VoidCallback onToggle;

  /// 閉じているときの 1 行。
  final Widget peek;

  /// 開いたときの中身（タブ + パネル）。
  final Widget body;

  /// 閉じているときの高さ。
  static const closedHeight = 116.0;

  /// 中身が縮まずに入る最小の高さ。
  /// タブの段（[SegmentedTabs.height] + 上下の余白 14）+ パネルの見出し 44 +
  /// 余白 で、リストが 0 行でも溢れない値。
  static const _minBodyHeight = SegmentedTabs.height + 14 + 44 + 44;

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
                onTap: onToggle,
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -120 && !open) {
                    onToggle();
                  } else if (velocity > 120 && open) {
                    onToggle();
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // **開いた瞬間はまだシートが伸びていない。** open は即座に
                    // 反転するが、高さを動かすのは AnimatedPositioned なので、
                    // 最初の 1 フレームは閉じたときの高さで組まれる。そこに
                    // 本体を入れると Column が溢れて赤縞が出るので、収まる
                    // 高さになるまで 1 行プレビューのままにしておく。
                    final fits = constraints.maxHeight >= _minBodyHeight;
                    return open && fits ? body : peek;
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

/// スマホ全体（now playing の上にシートが被さる）。
class PhoneSourceScaffold extends StatelessWidget {
  const PhoneSourceScaffold({
    super.key,
    required this.nowPlaying,
    required this.sheet,
    required this.sheetOpen,
    required this.topInset,
  });

  final Widget nowPlaying;
  final Widget sheet;
  final bool sheetOpen;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 割合はステータスバーを除いた「中身が使える高さ」に掛ける。
        // 全高に掛けると、上に隠れている帯のぶんシートが伸びる。
        final sheetHeight = sheetOpen
            ? (constraints.maxHeight - topInset) * 0.78
            : SourceSheet.closedHeight;

        return Stack(
          children: [
            Positioned.fill(
              bottom: SourceSheet.closedHeight,
              child: nowPlaying,
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              left: 0,
              right: 0,
              bottom: 0,
              height: sheetHeight,
              child: sheet,
            ),
          ],
        );
      },
    );
  }
}
