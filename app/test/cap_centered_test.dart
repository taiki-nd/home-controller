import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/widgets/atoms.dart';

/// テストの既定フォントは metrics が本物と違うので、実物を読ませる。
/// dart:io の Future は FakeAsync の中では完了しないため runAsync で回す。
Future<void> loadBodyFont(WidgetTester tester) async {
  await tester.runAsync(() async {
    final loader = FontLoader('ZenKakuGothicNew');
    for (final path in const [
      'assets/fonts/ZenKakuGothicNew-Regular.ttf',
      'assets/fonts/ZenKakuGothicNew-Bold.ttf',
    ]) {
      loader.addFont(
        File(path).readAsBytes().then((bytes) => ByteData.view(bytes.buffer)),
      );
    }
    await loader.load();
  });
}

void main() {
  // Zen Kaku Gothic New の OS/2 cap height は 700/1000。
  const capHeight = 0.70;

  // 点と横に並べたときに文字だけ沈んで見えないこと。行の箱は ascent 1.160em /
  // descent 0.288em で切られるので、字面の中心は箱の中心より下に落ちる。
  // CapCentered はそのぶんを持ち上げる係数を 1 つで持っているので、
  // 実際に使うサイズすべてで効いているかを確かめる。
  testWidgets('字面の中心が行の箱の中心に乗る', (tester) async {
    await loadBodyFont(tester);

    // 13/14 はデバイスピル、16/12 はデバイス一覧の行。
    for (final fontSize in const [12.0, 13.0, 14.0, 16.0]) {
      final painter = TextPainter(
        text: TextSpan(
          text: 'WiiM Ultra',
          style: AppText.body(fontSize, weight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final baseline = painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      // ascent 1.160em を実際に踏んでいることの確認も兼ねる。
      expect(baseline, closeTo(fontSize * 1.160, 0.01));

      final inkCenter = baseline - fontSize * capHeight / 2;
      final wanted = inkCenter - painter.height / 2;

      expect(
        CapCentered.liftFor(fontSize),
        closeTo(wanted, 0.2),
        reason: '$fontSize px で字面が ${wanted.toStringAsFixed(2)}px 沈む',
      );
    }
  });
}
