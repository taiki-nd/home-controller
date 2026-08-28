import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// `background: #1ed760` の主アクション（Connect / Add to queue / Play now 確定）。
class GreenButton extends StatelessWidget {
  const GreenButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.fontSize = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
  });

  final String label;
  final VoidCallback? onPressed;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return _PillBase(
      onPressed: onPressed,
      background: AppColors.green,
      hoverBackground: AppColors.greenHover,
      padding: padding,
      child: Text(
        label,
        style: AppText.body(
          fontSize,
          weight: FontWeight.w900,
          color: AppColors.onGreen,
        ),
      ),
    );
  }
}

/// `background: #fff; color: #101014` の確定ボタン。
class WhiteButton extends StatelessWidget {
  const WhiteButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.fontSize = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
  });

  final String label;
  final VoidCallback? onPressed;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return _PillBase(
      onPressed: onPressed,
      background: Colors.white,
      hoverBackground: Colors.white,
      hoverScale: 1.03,
      padding: padding,
      child: Text(
        label,
        style: AppText.body(
          fontSize,
          weight: FontWeight.w900,
          color: AppColors.onWhite,
        ),
      ),
    );
  }
}

/// `border: 1px solid rgba(255,255,255,.18); background: transparent` の副アクション。
class OutlineButton extends StatelessWidget {
  const OutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.fontSize = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
  });

  final String label;
  final VoidCallback? onPressed;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return _PillBase(
      onPressed: onPressed,
      background: Colors.transparent,
      hoverBackground: Colors.transparent,
      border: AppColors.white(0.18),
      hoverBorder: Colors.white,
      padding: padding,
      child: Text(
        label,
        style: AppText.body(
          fontSize,
          weight: FontWeight.w700,
          color: AppColors.white(0.7),
        ),
      ),
    );
  }
}

class _PillBase extends StatefulWidget {
  const _PillBase({
    required this.child,
    required this.onPressed,
    required this.background,
    required this.hoverBackground,
    required this.padding,
    this.border,
    this.hoverBorder,
    this.hoverScale = 1.0,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final Color background;
  final Color hoverBackground;
  final Color? border;
  final Color? hoverBorder;
  final EdgeInsets padding;
  final double hoverScale;

  @override
  State<_PillBase> createState() => _PillBaseState();
}

class _PillBaseState extends State<_PillBase> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final border = _hover ? (widget.hoverBorder ?? widget.border) : widget.border;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: AnimatedScale(
          scale: _hover && enabled ? widget.hoverScale : 1.0,
          duration: const Duration(milliseconds: 120),
          child: Material(
            color: _hover && enabled ? widget.hoverBackground : widget.background,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.pill,
              side: border == null
                  ? BorderSide.none
                  : BorderSide(color: border, width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onPressed,
              child: Container(
                constraints: const BoxConstraints(minHeight: kMinTapTarget),
                padding: widget.padding,
                alignment: Alignment.center,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 半透明ガラスのピル。デバイス選択・帰属表示に使う。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.pill,
        side: BorderSide(color: AppColors.white(0.16)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 本文フォント（Zen Kaku Gothic New）は仮名のぶん上が広く、行の箱が
/// ascent 1.160em / descent 0.288em で切られる。欧文の字面（cap height
/// 0.700em）はその箱の中心より (1.160 - 0.288 - 0.700) / 2 = 0.086em 下に
/// 落ちるので、点と横に並べると文字だけ沈んで見える。
///
/// 箱の高さは変えずに字面だけ持ち上げて、見た目の中心を箱の中心に戻す。
/// ピルや行の高さには響かない。
class CapCentered extends StatelessWidget {
  const CapCentered({super.key, required this.fontSize, required this.child});

  /// 中の文字のサイズ。持ち上げ量はこれに比例する。
  final double fontSize;

  final Widget child;

  /// 行の箱の高さが整数に丸められる都合で、実測は 13px で 0.079em、
  /// 14px で 0.096em、16px で 0.091em と少し振れる。13〜16px なら
  /// この 1 つの値で誤差 0.15px 以内に収まる。
  static const _lift = 0.086;

  static double liftFor(double fontSize) => fontSize * _lift;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(0, -liftFor(fontSize)),
      child: child,
    );
  }
}

/// デバイス状態を示す小さな点。再生中は脈打つ（`@keyframes pulseDot`）。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, this.size = 8, this.pulse = true});

  final Color color;
  final double size;
  final bool pulse;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 遅延初期化（late final の初期化子）にしてはいけない。pulse: false のまま
    // 一度も参照されずに破棄されると、dispose() の中で初めて Ticker を作ろうとして
    // 「Looking up a deactivated widget's ancestor is unsafe」で落ちる。
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    if (widget.pulse) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulse && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulse) return dot;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Opacity(
          opacity: 0.35 + 0.65 * t,
          child: Transform.scale(scale: 0.8 + 0.2 * t, child: child),
        );
      },
      child: dot,
    );
  }
}

/// アートワーク。読み込み前・失敗時は抽出済みの配色で塗る。
/// Spotify デザインガイドライン上、画像自体には何も重ねない（設計メモ §12）。
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.radius = AppRadius.art,
    this.placeholderColors,
    this.opacity = 1.0,
    this.shadow,
  });

  final String? url;
  final double size;
  final BorderRadius radius;
  final List<Color>? placeholderColors;
  final double opacity;
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final colors =
        placeholderColors ?? [AppColors.white(0.10), AppColors.white(0.04)];
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: SizedBox.square(dimension: size),
    );

    return Opacity(
      opacity: opacity,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(borderRadius: radius, boxShadow: shadow),
        child: ClipRRect(
          borderRadius: radius,
          child: url == null
              ? fallback
              : Image.network(
                  url!,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback,
                  frameBuilder: (context, child, frame, wasSync) {
                    if (wasSync || frame != null) {
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: child,
                      );
                    }
                    return fallback;
                  },
                ),
        ),
      ),
    );
  }
}

/// home / music を切り替える Drawer を開く ☰。
///
/// **画面の左上に固定で置く。** 常時表示になるので焼きつきの種ではあるが、
/// home は無操作 3 分で music に戻る（[AppShell.idleTimeout]）ので、同じ絵が
/// 何時間も残り続けることはない。輝度を落として面の差を小さくしてある。
class MenuButton extends StatelessWidget {
  const MenuButton({super.key, required this.onPressed, this.compact = false});

  final VoidCallback onPressed;
  final bool compact;

  /// 幅を固定する。デバイスピルの左に置くので、ここが伸び縮みすると
  /// ピルの点の x が動き、デバイス一覧のポップオーバーと縦に揃わなくなる。
  static const slotWidth = kMinTapTarget;

  /// ピルとの間隔。[slotWidth] と合わせて、ピルが右へずれる量になる。
  static const gap = 8.0;

  /// [slotWidth] + [gap]。ピルの点の x を出すときに足す。
  static const shift = slotWidth + gap;

  @override
  Widget build(BuildContext context) {
    // IconButton は visualDensity ぶん自分で膨らむので、外から幅を締める。
    // ここが 1px でもずれるとポップオーバーの点が縦に揃わない。
    return SizedBox(
      width: slotWidth,
      height: slotWidth,
      child: IconButton(
        onPressed: onPressed,
        tooltip: 'メニュー',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: slotWidth,
          height: slotWidth,
        ),
        icon: Icon(
          Icons.menu,
          size: compact ? 20 : 22,
          color: AppColors.white(0.5),
        ),
      ),
    );
  }
}

/// `.18em` トラッキングの大文字ラベル。
class CapsLabel extends StatelessWidget {
  const CapsLabel(this.text, {super.key, this.size = 11, this.color});

  final String text;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: AppText.caps(size, color ?? AppColors.white(0.4)),
    );
  }
}

/// シャッフルのトグル。54x32 のトラックに 24px のノブ。
class ShuffleSwitch extends StatelessWidget {
  const ShuffleSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: 'シャッフル',
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: SizedBox(
          width: 54,
          height: kMinTapTarget,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 54,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: AppRadius.pill,
                color: value ? AppColors.green : AppColors.white(0.18),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// リスト行のホバー背景（`style-hover="background: rgba(255,255,255,.06)"`）。
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.child,
    this.onTap,
    this.padding = EdgeInsets.zero,
    this.radius = AppRadius.row,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final BorderRadius radius;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            borderRadius: widget.radius,
            color: _hover ? AppColors.white(0.06) : Colors.transparent,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

String formatDuration(Duration d) {
  final total = d.inSeconds.clamp(0, 86400);
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// 「次に鳴る 1 曲」を大きく見せるカード。
///
/// **music と QOBUZ で同じ形を使う。** どちらの Up next も、先頭だけは
/// 一覧から持ち上げて主役にする（あとは番号付きの行が続く）。
/// モデルを取らずに文字列で受けるのは、Spotify の `Track` と QOBUZ の
/// `QobuzTrack` の両方から作れるようにするため。
class NextUpCard extends StatelessWidget {
  const NextUpCard({
    super.key,
    required this.title,
    required this.accent,
    required this.compact,
    this.subtitle,
    this.imageUrl,
    this.trailing,
  });

  final String title;

  /// アーティスト名。QOBUZ 側は付いていない曲があるので出さない。
  final String? subtitle;
  final String? imageUrl;
  final Color accent;
  final bool compact;

  /// 行の右端（QOBUZ はここに「キューから外す」を置く）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        borderRadius: AppRadius.card,
        color: AppColors.white(0.07),
        border: Border.all(color: AppColors.white(0.1)),
      ),
      child: Row(
        children: [
          Artwork(
            url: imageUrl,
            size: compact ? 72 : 96,
            radius: AppRadius.thumb,
          ),
          SizedBox(width: compact ? 14 : 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                CapsLabel('Next up', size: compact ? 10 : 11, color: accent),
                SizedBox(height: compact ? 4 : 6),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 19 : 24,
                    weight: FontWeight.w900,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body(
                      compact ? 13 : 15,
                      color: AppColors.white(0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
