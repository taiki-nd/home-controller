import 'package:flutter/material.dart';

/// `Spotify Controller.dc.html` のデザインから起こしたトークン。
/// 数値・色は基本的にデザインの実値をそのまま持ってくる。
class AppColors {
  AppColors._();

  /// Spotify グリーン。プライマリアクション（Connect / Add to queue）専用。
  static const green = Color(0xFF1ED760);
  static const greenHover = Color(0xFF34E874);

  /// グリーン背景に載せる文字色。
  static const onGreen = Color(0xFF05170C);

  /// 白背景のボタンに載せる文字色。
  static const onWhite = Color(0xFF101014);

  /// アプリ全体の下地。
  static const bg = Color(0xFF08080A);
  static const frameBg = Color(0xFF0B0B0D);

  /// ダイアログ / ポップオーバーの面。
  static const surface = Color(0xFF16161B);
  static const popover = Color(0xFF141418);

  /// 停止中（204 NO CONTENT）を示すアンバー。エラー色ではない。
  static const amber = Color(0xFFFFC43D);
  static const amberText = Color(0xFFFFE6A8);
  static const onAmber = Color(0xFF2A1D00);

  /// デバイス消失（404 NO_ACTIVE_DEVICE）。
  static const danger = Color(0xFFFF6B6B);

  /// 非アクティブなデバイスドット。
  static const dotIdle = Color(0xFF666666);

  static Color white(double opacity) => Colors.white.withValues(alpha: opacity);
}

/// Space Grotesk（ラベル・数値用）と Zen Kaku Gothic New（本文用）。
class AppText {
  AppText._();

  static const bodyFamily = 'ZenKakuGothicNew';
  static const monoFamily = 'SpaceGrotesk';

  /// Space Grotesk は可変フォントなので wght 軸を明示する。
  static TextStyle grotesk({
    required double size,
    double weight = 500,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: monoFamily,
      fontVariations: [FontVariation('wght', weight)],
      fontSize: size,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  /// `letter-spacing: .18em; text-transform: uppercase` のキャップラベル。
  /// em 指定なのでサイズに比例させる。
  static TextStyle caps(double size, Color color, {double em = 0.18}) =>
      grotesk(size: size, weight: 700, color: color, letterSpacing: size * em);

  static TextStyle body(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: bodyFamily,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}

class AppRadius {
  AppRadius._();

  static const pill = BorderRadius.all(Radius.circular(999));
  static const card = BorderRadius.all(Radius.circular(16));
  static const dialog = BorderRadius.all(Radius.circular(24));
  static const popover = BorderRadius.all(Radius.circular(18));
  static const art = BorderRadius.all(Radius.circular(10));
  static const thumb = BorderRadius.all(Radius.circular(6));
  static const thumbSmall = BorderRadius.all(Radius.circular(4));
  static const row = BorderRadius.all(Radius.circular(12));
}

/// iPad（横）とスマホでレイアウトを切り替える閾値。
/// デザインは 1194x834（iPad landscape）と 390x844（iPhone）の 2 系統。
const double kTabletBreakpoint = 900;

/// タップターゲットの最小高。デザイン側の `min-height: 44px` に合わせる。
const double kMinTapTarget = 44;

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.green,
    onPrimary: AppColors.onGreen,
    surface: AppColors.surface,
    error: AppColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: AppText.bodyFamily,
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.green,
      selectionColor: Color(0x551ED760),
    ),
  );
}
