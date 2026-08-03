import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 縁が溶けている面。仕切りの線を引く代わりに、面の色そのものを隣の面へ
/// 繋いでしまう。
///
/// 壁掛けの iPad は同じ絵を何時間も出しっぱなしにするので、幅 1px・輝度一定の
/// 線がいちばん焼きつきやすい。線を暗くしても明るくしても、そこだけ他と違う
/// 明るさで焼かれ続けるのは同じ。なので線を置くのをやめて、こうする。
///
/// 1. [color] のアルファを縁から [ramp] px かけて 0→1 に立ち上げる。境目に
///    あるのは、隣の面の色からこの面の色への繋ぎだけ。線も、影も、白も、
///    黒も足さない。境界の位置は色が変わることで伝わる。
/// 2. その立ち上がり位置を [drift] px ぶん、[cycle] かけて往復させる。1 回の
///    [_step] で動くのは 1px 未満なので目には止まらないが、色が切り替わる
///    位置が時間で [drift] px にばらけるので、跡が線として残らない。
///
/// 動かすのは Timer で、フレーム連打はしない。止まっているとき（＝焼きつきが
/// いちばん怖いとき）も同じように動き続ける。
class SoftSurface extends StatelessWidget {
  const SoftSurface({
    super.key,
    required this.color,
    required this.edges,
    required this.child,
    this.ramp = defaultRamp,
    this.drift = defaultDrift,
    this.cycle = const Duration(minutes: 12),
  });

  /// この面の色。隣の面の上に載るので、透ける色でよい。
  final Color color;

  /// 溶かす辺。[AxisDirection.left] なら左端が隣の面へ繋がる。複数渡すと、
  /// それぞれの立ち上がりを掛け合わせた形（角では両方効く）になる。
  final List<AxisDirection> edges;

  final Widget child;

  /// 隣の面の色からこの面の色に変わりきるまでの距離。
  final double ramp;

  /// 変わりきる位置が往復する幅。
  final double drift;

  /// 往復 1 周にかける時間。
  final Duration cycle;

  /// 繋ぎに使う既定の距離。両隣の中身に掛かるので、境目の余白（レール左は
  /// 40/24、レール内の横の仕切りは 15/16）に収まる範囲でいちばん広く取る。
  static const defaultRamp = 26.0;
  static const defaultDrift = 10.0;

  /// 縁から、色が完全にこの面の色になるまでの最大距離。
  static const defaultSpan = defaultRamp + defaultDrift;

  @override
  Widget build(BuildContext context) {
    return _Drift(
      cycle: cycle,
      builder: (context, phase) {
        // 往復させる。端で折り返すので、どこかに滞留する瞬間がない。
        final start = drift * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
        return CustomPaint(
          painter: _SoftSurfacePainter(
            color: color,
            edges: edges,
            ramp: ramp,
            start: start,
          ),
          child: child,
        );
      },
    );
  }
}

/// 0→1 を [cycle] かけて 1 周する位相を、フレームを回さずに刻む。
class _Drift extends StatefulWidget {
  const _Drift({required this.cycle, required this.builder});

  final Duration cycle;
  final Widget Function(BuildContext, double) builder;

  @override
  State<_Drift> createState() => _DriftState();
}

class _DriftState extends State<_Drift> {
  /// 位相を進める間隔。1 ステップの移動量が 1px を切るよう十分細かく刻む。
  static const _step = Duration(seconds: 20);

  Timer? _timer;
  double _phase = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_step, (_) {
      final per = _step.inMilliseconds / widget.cycle.inMilliseconds;
      setState(() => _phase = (_phase + per) % 1.0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _phase);
}

class _SoftSurfacePainter extends CustomPainter {
  const _SoftSurfacePainter({
    required this.color,
    required this.edges,
    required this.ramp,
    required this.start,
  });

  final Color color;
  final List<AxisDirection> edges;
  final double ramp;

  /// 縁から何 px 内側で色が立ち上がり始めるか。
  final double start;

  @override
  void paint(Canvas canvas, Size size) {
    if (edges.isEmpty || size.isEmpty) return;
    final rect = Offset.zero & size;

    // 1 辺なら 1 回塗るだけ。2 辺以上は、1 枚目を残りの辺のアルファで削る。
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, Paint()..shader = _ramp(edges.first, size, color));
    for (final edge in edges.skip(1)) {
      canvas.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = _ramp(edge, size, const Color(0xFF000000)),
      );
    }
    canvas.restore();
  }

  /// [edge] から内側へ向かって透明→[tint] に立ち上がるグラデーション。
  /// 奥（＝反対側）は [TileMode.clamp] で塗り切られる。
  Shader _ramp(AxisDirection edge, Size size, Color tint) {
    final (begin, end, full) = switch (edge) {
      AxisDirection.left => (
        Alignment.centerLeft,
        Alignment.centerRight,
        size.width,
      ),
      AxisDirection.right => (
        Alignment.centerRight,
        Alignment.centerLeft,
        size.width,
      ),
      AxisDirection.up => (
        Alignment.topCenter,
        Alignment.bottomCenter,
        size.height,
      ),
      AxisDirection.down => (
        Alignment.bottomCenter,
        Alignment.topCenter,
        size.height,
      ),
    };
    final rect = Offset.zero & size;
    return LinearGradient(
      begin: begin,
      end: end,
      colors: [tint.withValues(alpha: 0), tint],
      stops: [
        (start / full).clamp(0.0, 1.0),
        ((start + ramp) / full).clamp(0.0, 1.0),
      ],
    ).createShader(rect);
  }

  @override
  bool shouldRepaint(_SoftSurfacePainter old) =>
      old.color != color ||
      !listEquals(old.edges, edges) ||
      old.ramp != ramp ||
      old.start != start;
}
