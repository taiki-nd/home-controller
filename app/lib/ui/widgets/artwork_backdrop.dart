import 'package:flutter/material.dart';

import '../../state/playback_surface.dart';
import '../../theme/tokens.dart';

/// アートワーク由来の背景。**再生画面の地の色はここに一本化する。**
///
/// Spotify（`ControllerScreen`）と Qobuz（`QobuzView`）で同じ絵にするための
/// 切り出し。色の出どころ（`ArtworkPaletteResolver`）だけ揃えても、掛け方が
/// 食い違えば別物に見えるので、グラデーションと暗幕はここに置く。
///
/// 2 枚重ねになっている:
///
/// 1. **地** — 停止中は色を落として「鳴っていない」ことを画面全体で示す
/// 2. **暗幕** — アートワーク由来の色が明るいときに文字が沈まないよう覆う。
///    横長は左上から丸く、縦長は上から下へ。**同じ暗さを一様に掛けない**のは、
///    情報が寄っている側だけを暗くしたいから
class ArtworkBackdrop extends StatelessWidget {
  const ArtworkBackdrop({
    super.key,
    required this.palette,
    required this.stopped,
    required this.wide,
    required this.child,
  });

  final ArtworkPalette palette;

  /// 鳴らすものが無い。地の色を落とす。
  final bool stopped;

  /// タブレット幅（暗幕の掛け方が変わる）。
  final bool wide;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gradient = stopped
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF14140F), AppColors.frameBg],
            stops: [0, 0.7],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [palette.deep, palette.accent, AppColors.frameBg],
            stops: const [0, 0.55, 1],
          );

    return AnimatedContainer(
      // 曲が変わったときに色が飛ばないよう、地は必ず溶かして変える。
      duration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(gradient: gradient),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: wide
              ? RadialGradient(
                  center: Alignment.topLeft,
                  radius: 1.4,
                  colors: [
                    Colors.black.withValues(alpha: 0.15),
                    Colors.black.withValues(alpha: 0.72),
                  ],
                  stops: const [0, 0.75],
                )
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.25),
                    Colors.black.withValues(alpha: 0.8),
                  ],
                ),
        ),
        child: child,
      ),
    );
  }
}
