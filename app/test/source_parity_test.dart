import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/main_mock.dart';
import 'package:spotify_remote/ui/widgets/source_layout.dart';
import 'package:spotify_remote/ui/widgets/transport.dart';

/// SPOTIFY と QOBUZ が**同じ器で組まれている**ことを見る。
///
/// 見た目を「似せた」だけだと、片方を直したときにもう片方が置いていかれる。
/// ここで押さえるのは寸法や色ではなく**同じ widget を通っていること**で、
/// それが崩れたら「揃えたつもりが揃っていない」に必ず戻る。
void main() {
  const ipad = Size(1194, 834);
  const iphone = Size(390, 844);

  Future<void> setSurface(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// モックを起動して、Drawer から音源を選ぶ。
  Future<void> open(WidgetTester tester, String label) async {
    await tester.pumpWidget(const MockApp());
    await tester.pump(const Duration(milliseconds: 400));
    drain(tester);

    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text(label)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    drain(tester);
  }

  /// 後始末。**アートワークが読めないと 15 秒のタイマーが残る。**
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 16));
    drain(tester);
  }

  group('iPad', () {
    for (final source in ['SPOTIFY', 'QOBUZ']) {
      testWidgets('$source は大判ペイン + レールで組まれる', (tester) async {
        await setSurface(tester, ipad);
        await open(tester, source);

        expect(find.byType(TabletNowPlaying), findsOneWidget);
        expect(find.byType(SourceRail), findsOneWidget);
        expect(find.byType(SourceArtwork), findsOneWidget);
        // レールの中に進捗とトランスポートが 1 組。
        expect(find.byType(ProgressRow), findsOneWidget);
        expect(find.byType(TransportControls), findsOneWidget);
        // スマホ用のシートは出さない。
        expect(find.byType(SourceSheet), findsNothing);

        await settle(tester);
      });
    }
  });

  group('iPhone', () {
    for (final source in ['SPOTIFY', 'QOBUZ']) {
      testWidgets('$source は now playing + ボトムシートで組まれる', (tester) async {
        await setSurface(tester, iphone);
        await open(tester, source);

        expect(find.byType(PhoneSourceScaffold), findsOneWidget);
        expect(find.byType(PhoneNowPlaying), findsOneWidget);
        expect(find.byType(SourceSheet), findsOneWidget);
        expect(find.byType(SourceArtwork), findsOneWidget);
        expect(find.byType(ProgressRow), findsOneWidget);
        expect(find.byType(TransportControls), findsOneWidget);
        // iPad 用のレールは出さない。
        expect(find.byType(SourceRail), findsNothing);

        await settle(tester);
      });
    }
  });

  group('タブ', () {
    /// 見えているタブの文言を左から順に。IndexedStack で隠れているほうの
    /// 音源は既定で拾わないので、これで「今出ている音源のタブ」になる。
    List<String> labels(WidgetTester tester) => tester
        .widgetList<TabButton>(find.byType(TabButton))
        .map((tab) => tab.label)
        .toList();

    /// スマホはシートを開かないとタブが組まれない。掴みしろを叩いて開ける。
    Future<void> openSheet(WidgetTester tester) async {
      // Drawer が閉じきるまで待つ。残っているとバリアが叩きを吸う。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      final sheet = tester.getRect(find.byType(SourceSheet));
      await tester.tapAt(sheet.topCenter + const Offset(0, 15));
      // 1 回目で open が立ち、2 回目でシートが伸びきる。伸びきるまでは中身が
      // 収まらないので、1 行プレビューのままタブは組まれない。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
    }

    testWidgets('iPad: 文言も並びも音源で変わらない', (tester) async {
      await setSurface(tester, ipad);

      await open(tester, 'SPOTIFY');
      expect(find.byType(SegmentedTabs), findsOneWidget);
      final music = labels(tester);
      await settle(tester);

      await open(tester, 'QOBUZ');
      expect(find.byType(SegmentedTabs), findsOneWidget);
      final qobuz = labels(tester);
      await settle(tester);

      expect(music, ['Up next', 'Library', 'Add tracks', 'New']);
      // QOBUZ に New は無い。**抜けるのはそれだけで、残りは 1 語も並びも同じ。**
      expect(qobuz, music.where((label) => label != 'New').toList());
    });

    testWidgets('iPhone: 短い文言になるが、揃っているのは同じ', (tester) async {
      await setSurface(tester, iphone);

      await open(tester, 'SPOTIFY');
      await openSheet(tester);
      final music = labels(tester);
      await settle(tester);

      await open(tester, 'QOBUZ');
      await openSheet(tester);
      final qobuz = labels(tester);
      await settle(tester);

      // 4 つ並べる幅がないので Library / Add tracks だけ短くする。
      expect(music, ['Up next', 'Lists', 'Add', 'New']);
      // **片方だけ短くしない。** iPad と違って QOBUZ も短いほうに揃える。
      expect(qobuz, music.where((label) => label != 'New').toList());
    });
  });
}

/// モックのアートワークは web/mock/*.png を HTTP で読む。テスト環境では必ず
/// 400 になるので、器の確認には関係ないぶんを捨てる。
void drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}
