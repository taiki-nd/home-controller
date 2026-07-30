import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// アートワークを左右にスワイプして曲送りする当たり判定。
///
/// 左へ払う = 次の曲、右へ払う = 前の曲（トランスポートの ◀◀ / ▶▶ と同じ向き）。
/// 指には追従させるが、離すまで何も起きない。指を戻せば取り消せる。
///
/// 曲送りは `POST /me/player/next` → 400ms 待ち → 再ポーリングで、実際に
/// 画面の曲名が変わるのは 0.5 秒ほど後になる。それを待ってからカードを
/// 動かすと反応が鈍く感じるので、見た目の動きと API の往復は切り離してある。
/// 「受け付けた」ことは払った向きへのスライドで示し、中身の差し替えは
/// [Artwork] 側のクロスフェードに任せる。
class SwipeSkip extends StatefulWidget {
  const SwipeSkip({
    super.key,
    required this.size,
    required this.onNext,
    required this.onPrevious,
    required this.child,
    this.enabled = true,
  });

  /// アートワークの一辺。引っぱる量・払う量をこれに比例させる。
  final double size;

  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Widget child;

  /// デバイス消失中は前後ボタンと同じく効かせない。
  final bool enabled;

  @override
  State<SwipeSkip> createState() => _SwipeSkipState();
}

enum _Phase { idle, drag, cancel, commit }

class _SwipeSkipState extends State<SwipeSkip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this);

  _Phase _phase = _Phase.idle;

  /// 指の移動量（生の値）。見かけの位置は [_rubber] を通したもの。
  double _drag = 0;

  /// アニメーション開始時の見かけの位置。
  double _from = 0;

  /// カードが出ていく向き。次の曲 = 左 = -1。
  int _dir = -1;

  /// コミット時、前半（出ていく）に使う時間の割合。
  static const _exitShare = 0.4;

  /// 引っぱりの漸近線。ここまでは近づくが超えない。
  double get _pull => widget.size * 0.55;

  /// 払ったときに滑らせる距離。透明になりきるので隣の要素には被らない。
  double get _travel => widget.size * 0.38;

  /// ここまで引いたら離した時点で確定。
  double get _threshold => widget.size * 0.14;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// 引くほど鈍くなるゴムバンド。0 での傾きは 1 なので、最初は指に付いてくる。
  double _rubber(double raw) {
    final x = raw.abs();
    return raw.sign * (1 - 1 / (x / _pull + 1)) * _pull;
  }

  double get _offset {
    switch (_phase) {
      case _Phase.idle:
        return 0;
      case _Phase.drag:
        return _rubber(_drag);
      case _Phase.cancel:
        // 行きすぎて戻るばね。取り消したことがはっきり分かる。
        final t = Curves.easeOutBack.transform(_anim.value);
        return lerpDouble(_from, 0, t)!;
      case _Phase.commit:
        final t = _anim.value;
        if (t < _exitShare) {
          final e = Curves.easeOut.transform(t / _exitShare);
          return lerpDouble(_from, _dir * _travel, e)!;
        }
        // 払った向きの逆から入れ替わりで戻ってくる。
        final e = Curves.easeOutCubic.transform(
          (t - _exitShare) / (1 - _exitShare),
        );
        return lerpDouble(-_dir * _travel, 0, e)!;
    }
  }

  double get _opacity {
    if (_phase != _Phase.commit) return 1;
    final t = _anim.value;
    if (t < _exitShare) return math.max(0, 1 - t / _exitShare);
    return ((t - _exitShare) / (1 - _exitShare)).clamp(0.0, 1.0);
  }

  void _onStart(DragStartDetails details) {
    _anim.stop();
    setState(() {
      _phase = _Phase.drag;
      _drag = 0;
    });
  }

  void _onUpdate(DragUpdateDetails details) {
    setState(() => _drag += details.delta.dx);
  }

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    // ゆっくり大きく引く／速く弾く、どちらでも確定させる。
    // 弾き側に最低距離を課すのは、タップの微動で送らないため。
    final commit =
        _drag.abs() >= _threshold ||
        (velocity.abs() >= 420 && _drag.abs() >= 12);
    if (!commit) {
      _startCancel();
      return;
    }

    final next = _drag < 0;
    _from = _rubber(_drag);
    _dir = next ? -1 : 1;
    setState(() => _phase = _Phase.commit);
    _anim
      ..duration = const Duration(milliseconds: 430)
      ..forward(from: 0);
    // 待たずに投げる。返りを待つと 0.5 秒無反応に見える。
    (next ? widget.onNext : widget.onPrevious)();
  }

  void _startCancel() {
    _from = _rubber(_drag);
    setState(() => _phase = _Phase.cancel);
    _anim
      ..duration = const Duration(milliseconds: 300)
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return GestureDetector(
      // 影のぶんは外れるが、画像そのものはどこを触っても掴める。
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: enabled ? _onStart : null,
      onHorizontalDragUpdate: enabled ? _onUpdate : null,
      onHorizontalDragEnd: enabled ? _onEnd : null,
      onHorizontalDragCancel: enabled ? _startCancel : null,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final opacity = _opacity;
          return Transform.translate(
            offset: Offset(_offset, 0),
            child: opacity >= 1
                ? child
                : Opacity(opacity: opacity, child: child),
          );
        },
        child: widget.child,
      ),
    );
  }
}
