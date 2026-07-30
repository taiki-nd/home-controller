import 'dart:math' as math;

import 'package:flutter/material.dart';

/// アートワークの外側を光源が一周する演出。
///
/// 光源そのものはカバーに被らない位置（盤の外）を回っていて、画面に出るのは
/// その結果だけ — 外へ漏れるグロー、逆側へ伸びる影、そして光の当たっている面の
/// ツヤ。枠や縁のような常設のパーツは足さないので、レイアウトも変わらない
/// （このウィジェットの大きさ = [size]）。UI が増えるのではなく、カバー画像の
/// 見え方だけが変わる。
///
/// 光源は右上（-45°）から時計回りに [period] で一周する。止まっているとき
/// （[active] = false）は回転を止めて光量も落とす。
class OrbitingLight extends StatefulWidget {
  const OrbitingLight({
    super.key,
    required this.size,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(10)),
    this.tint,
    this.period = const Duration(seconds: 11),
    this.active = true,
  });

  /// アートワークの一辺。このウィジェットもちょうどこの大きさになる。
  final double size;

  final Widget child;

  /// 中身の角丸。ツヤをここに合わせて切り抜く。
  final BorderRadius radius;

  /// 光の色。アートワークから抽出した色を渡すと馴染む。既定は白寄り。
  final Color? tint;

  /// 光源が一周する時間。
  final Duration period;

  /// 再生中だけ回す。止まっているときは光量を落として固定。
  final bool active;

  @override
  State<OrbitingLight> createState() => _OrbitingLightState();
}

class _OrbitingLightState extends State<OrbitingLight>
    with TickerProviderStateMixin {
  /// 光源の周回。0→1 で一周。
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  /// 光量。active の切り替えで滑らかに増減させる。
  late final AnimationController _level = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    value: widget.active ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _orbit.repeat();
  }

  @override
  void didUpdateWidget(OrbitingLight old) {
    super.didUpdateWidget(old);
    if (widget.period != old.period) _orbit.duration = widget.period;
    if (widget.active == old.active) return;
    if (widget.active) {
      _orbit.repeat();
      _level.forward();
    } else {
      // 回転は止めるが、光量が落ちきるまでは今の角度のまま残す。
      _orbit.stop();
      _level.reverse();
    }
  }

  @override
  void dispose() {
    _orbit.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 「視差効果を減らす」設定では回さない。光り方だけ静止した状態で残す。
    if (MediaQuery.disableAnimationsOf(context) && _orbit.isAnimating) {
      _orbit.stop();
    }

    final tint = widget.tint ?? const Color(0xFFBFD4FF);

    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_orbit, _level]),
        builder: (context, child) {
          // 右上から始めて時計回り。
          final angle = -math.pi / 4 + _orbit.value * 2 * math.pi;
          final level = Curves.easeOut.transform(_level.value);
          final painter = _LightPainter(
            angle: angle,
            // 消灯時もツヤが完全には死なないよう下限を残す。
            intensity: 0.30 + 0.70 * level,
            radius: widget.radius,
            tint: tint,
          );
          return CustomPaint(
            painter: painter.forLayer(foreground: false),
            foregroundPainter: painter.forLayer(foreground: true),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// 背面（影とグロー）と前面（ツヤ）の両方を描く。[foreground] で描き分ける。
class _LightPainter extends CustomPainter {
  const _LightPainter({
    required this.angle,
    required this.intensity,
    required this.radius,
    required this.tint,
    this.foreground = false,
  });

  final double angle;
  final double intensity;
  final BorderRadius radius;
  final Color tint;
  final bool foreground;

  _LightPainter forLayer({required bool foreground}) => _LightPainter(
    angle: angle,
    intensity: intensity,
    radius: radius,
    tint: tint,
    foreground: foreground,
  );

  /// 光源の向きの単位ベクトル。
  Offset get _dir => Offset(math.cos(angle), math.sin(angle));

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.resolve(TextDirection.ltr).toRRect(rect);
    if (foreground) {
      _paintSheen(canvas, rect, rrect);
    } else {
      _paintShadow(canvas, rect, rrect);
    }
  }

  /// カバーの裏に置く影とグロー。カバーは不透明なので、外へはみ出したぶんだけが
  /// 見える = 盤の外を回る光源そのものの位置に見える。
  void _paintShadow(Canvas canvas, Rect rect, RRect rrect) {
    final dir = _dir;
    final w = rect.width;

    // 影は必ず下方向の成分を持たせる。真横から当たっても浮いて見えるように。
    final drop = Offset(
      -dir.dx * w * 0.06,
      rect.height * 0.06,
    ).translate(0, -dir.dy * rect.height * 0.05);
    canvas.drawRRect(
      rrect.shift(drop).deflate(w * 0.05),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55 + 0.25 * intensity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.10),
    );

    // 光源側へ漏れる色。回っているのがいちばん分かるのはこの滲み。
    canvas.drawRRect(
      rrect.shift(dir * w * 0.055).deflate(w * 0.03),
      Paint()
        ..color = tint.withValues(alpha: 0.32 * intensity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.09),
    );
  }

  /// 光の当たっている面のツヤ。盤の外の光源から届いた光が表面をなめる形なので、
  /// 光源側が明るく、反対側へ向かって消える。輪郭のような線は置かない。
  void _paintSheen(Canvas canvas, Rect rect, RRect rrect) {
    canvas.save();
    canvas.clipRRect(rrect);

    // 光源はカバーの外。そこを中心にした落ち込みで面を照らす。
    final source = rect.center + _dir * (rect.width * 0.78);
    final beam = Rect.fromCircle(center: source, radius: rect.width * 1.05);
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.22 * intensity),
            tint.withValues(alpha: 0.09 * intensity),
            const Color(0x00000000),
          ],
          stops: const [0.0, 0.42, 1.0],
        ).createShader(beam),
    );

    // ふちの立ち上がり。光源側だけ細く光って、回りながら消えていく。
    canvas.drawRRect(
      rrect.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..blendMode = BlendMode.plus
        ..shader = SweepGradient(
          transform: GradientRotation(angle - math.pi),
          colors: [
            const Color(0x00000000),
            tint.withValues(alpha: 0.14 * intensity),
            Colors.white.withValues(alpha: 0.45 * intensity),
            tint.withValues(alpha: 0.14 * intensity),
            const Color(0x00000000),
          ],
          stops: const [0.22, 0.40, 0.5, 0.60, 0.78],
        ).createShader(rect),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_LightPainter old) =>
      old.angle != angle ||
      old.intensity != intensity ||
      old.tint != tint ||
      old.foreground != foreground;
}
