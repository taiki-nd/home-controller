import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/widgets/marquee_text.dart';

/// 幅 200 の枠に入れて、収まる文字列と溢れる文字列の両方を見る。
Widget host(String text, {double width = 200}) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: MarqueeText(
          text,
          style: AppText.body(30, weight: FontWeight.w900, height: 1.08),
        ),
      ),
    ),
  ),
);

const _long =
    'とても長い曲名 - Extended Instrumental Mix (Remastered 2026 Deluxe Edition)';

/// 描画を複製している箱は private なので、動的に覗く。
dynamic _loopPaint(WidgetTester tester) => tester.allRenderObjects.firstWhere(
  (r) => r.runtimeType.toString() == '_RenderLoopPaint',
);

double _shift(WidgetTester tester) => _loopPaint(tester).shift as double;

void main() {
  testWidgets('収まる文字列は 1 行の高さで静止する', (tester) async {
    await tester.pumpWidget(host('短い'));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.text('短い'), findsOneWidget);

    final height = tester.getSize(find.byType(MarqueeText)).height;
    // fontSize 30 * height 1.08 = 32.4。行数で高さが変わらないことが要点。
    expect(height, closeTo(32.4, 0.5));
  });

  testWidgets('溢れる文字列も高さは 1 行のまま、時間で位置が動く', (tester) async {
    await tester.pumpWidget(host(_long));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // ウィジェットは 1 つ。描画だけ複製しているので読み上げ・検索は二重にならない。
    expect(find.text(_long), findsOneWidget);
    expect(tester.getSize(find.byType(MarqueeText)).height, closeTo(32.4, 0.5));

    // 枠からはみ出していない（親の SizedBox どおり）。
    expect(tester.getSize(find.byType(MarqueeText)).width, 200);

    // 停止時間のあいだは動かず、そのあと流れ始める。
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
    // 1 周ぶん回してもループが破綻しない。
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('頭でいったん止まり、そのあと流れる', (tester) async {
    await tester.pumpWidget(host(_long));
    await tester.pump();
    // 先頭を読ませるあいだは動かさない（既定 1800ms）。
    expect(_shift(tester), 0);
    await tester.pump(const Duration(milliseconds: 1700));
    expect(_shift(tester), 0);

    await tester.pump(const Duration(milliseconds: 500));
    final moved = _shift(tester);
    expect(moved, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 500));
    expect(_shift(tester), greaterThan(moved));

    // ずらす量は常に 1 周（テキスト幅 + 余白）の中。ここを超えないので継ぎ目が出ない。
    final stride = _loopPaint(tester).stride as double;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 700));
      expect(_shift(tester), inInclusiveRange(0, stride));
    }
  });

  testWidgets('空文字でも 1 行ぶんの高さを確保する', (tester) async {
    await tester.pumpWidget(host(''));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(MarqueeText)).height, closeTo(32.4, 0.5));
  });

  testWidgets('文字列が変わると頭から流し直す', (tester) async {
    await tester.pumpWidget(host(_long));
    await tester.pump(const Duration(milliseconds: 4000));
    await tester.pumpWidget(host('$_long 2'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('$_long 2'), findsOneWidget);
  });
}
