import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 折り返さずに 1 行で見せるテキスト。収まらないぶんは横へ流す。
///
/// 曲名・アーティスト名は長さが読めない。折り返しを許すと行数で高さが変わり、
/// 同じ列に積んでいるアートワークの位置が曲ごとにズレてしまう（設計上ここが一番痛い）。
/// そこでこのウィジェットは、
///
/// - 高さを常に 1 行ぶんに固定する（空文字でも同じ高さを確保する）
/// - 収まるときは静止した [Text] と同じ見た目にする（無駄に動かさない）
/// - 溢れるときだけ、末尾に余白を挟んで切れ目なくループさせる
///
/// の 3 つを守る。
class MarqueeText extends StatelessWidget {
  const MarqueeText(
    this.text, {
    super.key,
    required this.style,
    this.velocity,
    this.startPause = const Duration(milliseconds: 1800),
  });

  final String text;
  final TextStyle style;

  /// 流れる速さ（論理ピクセル/秒）。既定はフォントサイズから決める。
  /// 大きい見出しを小さい文字と同じ速さで流すと、体感では止まって見える。
  final double? velocity;

  /// 頭で止めておく時間。まず先頭から読ませて、それから流し始める。
  final Duration startPause;

  @override
  Widget build(BuildContext context) {
    // Text は DefaultTextStyle にマージしてから描く。同じ合成をしないと
    // 測った幅と実際に描かれる幅がズレる（M3 の既定は height を持っている）。
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final fontSize = scaler.scale(resolved.fontSize ?? 16);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: resolved),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        // 空文字の実測高は 0 になり得るので、スタイル由来の行高を下限にする。
        final lineHeight = math.max(
          painter.height,
          painter.preferredLineHeight,
        );
        painter.dispose();

        // 幅が測れない（無限）ときは動かしようがないので静止側に寄せる。
        final fits =
            !constraints.hasBoundedWidth ||
            textWidth <= constraints.maxWidth + 0.5;

        if (fits) {
          return SizedBox(
            height: lineHeight,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: resolved,
              ),
            ),
          );
        }

        return _Marquee(
          text: text,
          style: resolved,
          width: constraints.maxWidth,
          height: lineHeight,
          textWidth: textWidth,
          // 余白 = 「ここで一周した」と分かる間。文字サイズに比例させる。
          gap: (fontSize * 1.8).clamp(28.0, 96.0),
          fade: (fontSize * 0.7).clamp(14.0, 36.0),
          velocity: velocity ?? (fontSize * 1.5).clamp(36.0, 96.0),
          startPause: startPause,
        );
      },
    );
  }
}

/// 溢れているときだけ生きるループ本体。
class _Marquee extends StatefulWidget {
  const _Marquee({
    required this.text,
    required this.style,
    required this.width,
    required this.height,
    required this.textWidth,
    required this.gap,
    required this.fade,
    required this.velocity,
    required this.startPause,
  });

  final String text;
  final TextStyle style;
  final double width;
  final double height;
  final double textWidth;
  final double gap;
  final double fade;
  final double velocity;
  final Duration startPause;

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 1 周の距離。ここまで流すと 2 枚目が 1 枚目の位置にぴったり重なる。
  double get _stride => widget.textWidth + widget.gap;

  Duration get _cycle =>
      widget.startPause +
      Duration(milliseconds: (_stride / widget.velocity * 1000).round());

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _cycle)..repeat();
  }

  @override
  void didUpdateWidget(_Marquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 曲が変わった / 幅が変わったら頭から流し直す。途中から始まると読み落とす。
    if (oldWidget.text != widget.text ||
        oldWidget.textWidth != widget.textWidth ||
        oldWidget.gap != widget.gap ||
        oldWidget.velocity != widget.velocity ||
        oldWidget.startPause != widget.startPause) {
      _controller
        ..stop()
        ..duration = _cycle
        // repeat() は現在値から回り始めるので、明示的に頭へ戻す。
        ..value = 0
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// いま何ピクセル左にずらしているか。停止時間のあいだは 0 のまま。
  double get _shift {
    final total = _controller.duration!.inMilliseconds;
    final pause = widget.startPause.inMilliseconds;
    final travel = total - pause;
    if (travel <= 0) return 0;
    final elapsed = _controller.value * total;
    if (elapsed <= pause) return 0;
    return (elapsed - pause) / travel * _stride;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final shift = _shift;
            return ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => _edgeFade(rect, shift),
              child: _LoopPaint(shift: shift, stride: _stride, child: child!),
            );
          },
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: widget.style,
          ),
        ),
      ),
    );
  }

  /// 両端のぼかし。切れ目を隠すためで、
  /// 頭に戻っているあいだは左端をぼかさない（1 文字目が薄くなるとみっともない）。
  Shader _edgeFade(Rect rect, double shift) {
    final span = (widget.fade / rect.width).clamp(0.0, 0.45);
    final head = (shift / widget.fade).clamp(0.0, 1.0);
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Colors.white.withValues(alpha: 1 - head),
        Colors.white,
        Colors.white,
        Colors.transparent,
      ],
      stops: [0, span, 1 - span, 1],
    ).createShader(rect);
  }
}

/// 子を 1 周ぶんずらして、箱が埋まるまで描き直す。
///
/// [Text] を 2 つ並べても同じ絵にはなるが、セマンティクス（読み上げ）も
/// ウィジェット検索も二重になる。ウィジェットは 1 つのまま描画だけ複製する。
/// 子はレイヤを持たない [Text] 前提（Opacity などを挟むと同じレイヤを 2 度 push してしまう）。
class _LoopPaint extends SingleChildRenderObjectWidget {
  const _LoopPaint({
    required this.shift,
    required this.stride,
    required Widget super.child,
  });

  /// 左へずらす量。0 → [stride] を繰り返す。
  final double shift;

  /// 1 周の距離（テキスト幅 + 余白）。
  final double stride;

  @override
  _RenderLoopPaint createRenderObject(BuildContext context) =>
      _RenderLoopPaint(shift: shift, stride: stride);

  @override
  void updateRenderObject(BuildContext context, _RenderLoopPaint renderObject) {
    renderObject
      ..shift = shift
      ..stride = stride;
  }
}

class _RenderLoopPaint extends RenderProxyBox {
  _RenderLoopPaint({required double shift, required double stride})
    : _shift = shift,
      _stride = stride;

  double get shift => _shift;
  double _shift;
  set shift(double value) {
    if (_shift == value) return;
    _shift = value;
    markNeedsPaint();
  }

  double get stride => _stride;
  double _stride;
  set stride(double value) {
    if (_stride == value) return;
    _stride = value;
    markNeedsPaint();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('shift', shift));
    properties.add(DoubleProperty('stride', stride));
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void performLayout() {
    // 子は幅の制約を外して素の 1 行ぶんを測らせる。箱の大きさは親の指定どおり。
    child!.layout(const BoxConstraints(), parentUsesSize: true);
    size = constraints.biggest;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || _stride <= 0) return;
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) {
        for (var x = -_shift; x < size.width; x += _stride) {
          context.paintChild(child, offset + Offset(x, 0));
        }
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
