import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/ui/widgets/swipe_skip.dart';

const _size = 300.0;

void main() {
  late List<String> calls;

  Widget host({bool enabled = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SwipeSkip(
          size: _size,
          enabled: enabled,
          onNext: () => calls.add('next'),
          onPrevious: () => calls.add('previous'),
          child: Container(width: _size, height: _size, color: Colors.blue),
        ),
      ),
    ),
  );

  setUp(() => calls = []);

  /// 指を置いて [dx] だけ動かして離す。
  Future<void> swipe(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SwipeSkip)),
    );
    // 何回かに割って動かす（1 回だと速度が出て弾き判定になる）。
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(Offset(dx / 6, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    // 曲送りはカードが透明になりきってから投げる（入れ替わりを隠すため）ので、
    // そこまで進める。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('左へ払うと次の曲', (tester) async {
    await tester.pumpWidget(host());
    await swipe(tester, -80);
    expect(calls, ['next']);
  });

  testWidgets('右へ払うと前の曲', (tester) async {
    await tester.pumpWidget(host());
    await swipe(tester, 80);
    expect(calls, ['previous']);
  });

  testWidgets('少しだけ動かして戻すと何も起きない', (tester) async {
    await tester.pumpWidget(host());
    // しきい値は size * 0.14 = 42px。
    await swipe(tester, -30);
    expect(calls, isEmpty);

    // ばねで元位置に戻る。
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byType(SwipeSkip)).dx,
      closeTo(tester.getCenter(find.byType(Scaffold)).dx, 0.01),
    );
  });

  testWidgets('速く弾けばしきい値未満の距離でも次の曲', (tester) async {
    await tester.pumpWidget(host());
    // 50px。タッチスロップ（18px）を引くと 32px で、しきい値 42px には届かない。
    await tester.fling(find.byType(SwipeSkip), const Offset(-50, 0), 900);
    await tester.pump();
    // 払った直後はまだ投げない。カードが消えたところで 1 回だけ投げる。
    expect(calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, ['next']);
  });

  testWidgets('無効にしてあるあいだは動かない（デバイス消失中）', (tester) async {
    await tester.pumpWidget(host(enabled: false));
    await swipe(tester, -120);
    expect(calls, isEmpty);
  });

  testWidgets('指に追従し、離したあとは元の位置に戻る', (tester) async {
    await tester.pumpWidget(host());
    final home = tester.getTopLeft(find.byType(Container)).dx;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SwipeSkip)),
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    final pulled = tester.getTopLeft(find.byType(Container)).dx;
    // ゴムバンドなので指の移動量よりは小さい。でも確かに付いてくる。
    expect(pulled, lessThan(home));
    expect(pulled, greaterThan(home - 60));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(Container)).dx, closeTo(home, 0.01));
    expect(calls, ['next']);
  });

  testWidgets('縦スクロールは奪わない', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                SwipeSkip(
                  size: _size,
                  onNext: () => calls.add('next'),
                  onPrevious: () => calls.add('previous'),
                  child: Container(
                    width: _size,
                    height: _size,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );

    // アートワークの上から縦にドラッグしてもスクロールに回る
    // （タッチスロップぶんは食われるので 200 ちょうどにはならない）。
    await tester.drag(find.byType(SwipeSkip), const Offset(0, -200));
    await tester.pump();
    expect(scroll.offset, greaterThan(150));
    expect(calls, isEmpty);
  });
}
