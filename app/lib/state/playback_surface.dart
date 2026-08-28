import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:palette_generator/palette_generator.dart';

/// アートワークから抜いた 2 色。背景グラデーションにだけ使う。
/// （Spotify デザインガイドライン上、アートワーク自体の加工はできない — 設計メモ §12）
class ArtworkPalette {
  const ArtworkPalette(this.deep, this.accent);

  static const fallback = ArtworkPalette(Color(0xFF1D1D24), Color(0xFF4A4A5C));

  final Color deep;
  final Color accent;
}

/// 再生画面が要るものだけを抜いた口。
///
/// **音源が増えても再生画面は 1 つの作法に揃える。** Spotify（`PlayerController`）
/// と Qobuz（`QobuzController`）は中身がまるで別物——片方は Spotify Connect の
/// 機器に投げ、もう片方は LAN の WiiM に署名付き URL を投げる——だが、
/// 「いま何が鳴っていて、送る・止める・シークする」という**画面から見た形は
/// 同じ**。ここを共通の型にしておけば、`ProgressRow` や `TransportControls`
/// といった部品を両方から使い回せる。
///
/// **足すときは慎重に。** ここに増やしたものは両方の実装が持つ義務になる。
/// 片方にしか無いもの（Spotify のプレイリスト、Qobuz の音質バッジ）は
/// ここに入れず、それぞれの画面が自分のコントローラを直に見ればいい。
abstract class PlaybackSurface implements Listenable {
  /// 背景グラデーションの素。
  ArtworkPalette get palette;

  /// **シークバーだけを塗り替える口。**
  ///
  /// 進捗のたびに [Listenable] 本体を鳴らすと画面全部が作り直しになるので、
  /// 秒単位で動くものはこちらに分ける。
  Listenable get progressTick;

  Duration get position;
  Duration get duration;

  /// 0〜1。長さが取れないときは 0。
  double get progressFraction;

  bool get isPlaying;

  /// 鳴らすものが無い（＝時間の表示を 0 に伏せる）。
  bool get isStopped;

  /// 操作を受け付けられるか。**繋がっていないときは押させない。**
  /// Spotify なら機器を見失っていないこと、Qobuz なら WiiM に届くこと。
  bool get controlsEnabled;

  Future<void> togglePlayPause();
  Future<void> skipNext();
  Future<void> skipPrevious();
}

/// アートワークの URL から [ArtworkPalette] を作る。
///
/// **両方のコントローラで同じ絵作りにするために切り出してある。** 抽出の癖
/// （どの色を deep に採るか、取れなかったときにどう暗くするか）が食い違うと、
/// 音源を切り替えたときに同じ絵柄でも背景の印象が変わってしまう。
///
/// 直前に投げた URL を覚えていて、**同じ URL なら何もしない**。曲が変わって
/// いないのに毎回ネットワークから画像を引き直すのを防ぐ。
class ArtworkPaletteResolver {
  ArtworkPaletteResolver();

  ArtworkPalette _palette = ArtworkPalette.fallback;
  String? _sourceUrl;

  ArtworkPalette get palette => _palette;

  /// 抽出して、**色が変わったときだけ** true を返す（呼ぶ側はそのときだけ
  /// `notifyListeners` すればいい）。
  Future<bool> resolve(String? url) async {
    if (url == null || url == _sourceUrl) return false;
    _sourceUrl = url;
    try {
      final generated = await PaletteGenerator.fromImageProvider(
        NetworkImage(url),
        size: const ui.Size(120, 120),
        maximumColorCount: 12,
      );
      // 待っている間に次の曲へ行っていたら、古い結果は捨てる。
      if (_sourceUrl != url) return false;
      final accent =
          generated.vibrantColor?.color ??
          generated.lightVibrantColor?.color ??
          generated.dominantColor?.color ??
          ArtworkPalette.fallback.accent;
      final deep =
          generated.darkMutedColor?.color ??
          generated.darkVibrantColor?.color ??
          _darken(accent);
      _palette = ArtworkPalette(deep, accent);
      return true;
    } catch (e) {
      // 画像が取れないだけなので既定色で続行する。
      debugPrint('palette extraction failed: $e');
      return false;
    }
  }

  static Color _darken(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness * 0.35).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0))
        .toColor();
  }
}
