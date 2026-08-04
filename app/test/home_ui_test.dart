import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/main.dart';
import 'package:spotify_remote/main_mock.dart';
import 'package:spotify_remote/services/app_flags.dart';
import 'package:spotify_remote/state/home_controller.dart';
import 'package:spotify_remote/state/music_section.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/app_shell.dart';
import 'package:spotify_remote/ui/home/ha_setup_screen.dart';
import 'package:spotify_remote/ui/home/home_screen.dart';
import 'package:spotify_remote/ui/home/widgets/home_tiles.dart';
import 'package:spotify_remote/ui/music/music_view.dart';

import 'ha_support.dart';
import 'home_controller_test.dart' show ScriptedSocket, controllerFor;

/// iPad 横（デザインは 1194x834）。
const _ipad = Size(1194, 834);

Future<void> setSurface(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<HomeController> connected(ScriptedSocket socket) async {
  final controller = controllerFor(socket);
  await controller.start();
  return controller;
}

void main() {
  testWidgets('iPad: 部屋レールとタイルが実寸で破綻せず描画される', (tester) async {
    await setSurface(tester, _ipad);
    final controller = await connected(
      ScriptedSocket(
        states: [
          stateJson('light.ceiling', 'on', attributes: {
            'friendly_name': '天井',
            'brightness': 128,
            'supported_color_modes': ['brightness'],
          }),
          stateJson('switch.vent', 'off', attributes: {'friendly_name': '換気'}),
          stateJson('scene.night', 'unknown', attributes: {
            'friendly_name': 'おやすみ',
          }),
          stateJson('sensor.temp', '22.4', attributes: {
            'friendly_name': '室温',
            'device_class': 'temperature',
            'unit_of_measurement': '°C',
          }),
        ],
        areas: [
          {'area_id': 'living', 'name': 'リビング'},
        ],
        entities: [
          {'entity_id': 'light.ceiling', 'area_id': 'living'},
          {'entity_id': 'switch.vent', 'area_id': 'living'},
          {'entity_id': 'scene.night', 'area_id': 'living'},
          {'entity_id': 'sensor.temp', 'area_id': 'living'},
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(controller: controller, onOpenMenu: () {}),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('リビング'), findsOneWidget);
    // 押せるものはタイル、センサーは数値行。
    expect(find.byType(HomeTile), findsNWidgets(3));
    expect(find.text('22.4°C'), findsOneWidget);
    expect(find.text('ON · 50%'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('タイルを押すと即座に ON になる（HA の応答を待たない）', (tester) async {
    await setSurface(tester, _ipad);
    final controller = await connected(
      ScriptedSocket(
        states: [
          stateJson('switch.vent', 'off', attributes: {'friendly_name': '換気'}),
        ],
        answerCallService: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(controller: controller, onOpenMenu: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('OFF'), findsOneWidget);
    await tester.tap(find.byType(HomeTile));
    await tester.pump();
    expect(find.text('ON'), findsOneWidget);

    // 応答が無いまま放っておくと元に戻る。
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('OFF'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('応答なしの機器は押せない', (tester) async {
    await setSurface(tester, _ipad);
    final socket = ScriptedSocket(
      states: [
        stateJson('light.dead', 'unavailable', attributes: {
          'friendly_name': '寝室',
        }),
      ],
    );
    final controller = await connected(socket);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(controller: controller, onOpenMenu: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('応答なし'), findsOneWidget);
    final before = socket.sent.length;
    await tester.tap(find.byType(HomeTile));
    await tester.pump();
    expect(socket.sent.length, before);
    controller.dispose();
  });

  testWidgets('接続先が未設定なら設定画面が出る', (tester) async {
    await setSurface(tester, _ipad);
    final controller = HomeController(credentials: FakeHaCredentials());
    await controller.start();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomeScreen(controller: controller, onOpenMenu: () {}),
      ),
    );
    await tester.pump();

    expect(find.byType(HaSetupScreen), findsOneWidget);
    expect(find.text('Home Assistant に接続'), findsOneWidget);
    controller.dispose();
  });

  group('AppShell', () {
    testWidgets('music を持たないビルドでは Drawer に MUSIC が出ない', (tester) async {
      await setSurface(tester, _ipad);
      final controller = HomeController(credentials: FakeHaCredentials());
  
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(home: controller),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('メニュー').first);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME'), findsWidgets);
      expect(find.text('MUSIC'), findsNothing);
      // music が無いので IndexedStack ごと作らない。
      expect(find.byType(IndexedStack), findsNothing);
      controller.dispose();
    });

    testWidgets('home で無操作が続くと music に戻る（焼きつき対策）', (tester) async {
      await setSurface(tester, _ipad);
      mockSecureStorage();
      final home = HomeController(credentials: FakeHaCredentials());
      final music = MusicSection();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(home: home, music: music),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      int? index() =>
          tester.widget<IndexedStack>(find.byType(IndexedStack)).index;
      expect(index(), 0, reason: '起動時は必ず music（前回のモードを復元しない）');

      // music 側にも ☰ がある（帰属表示のピルの行に同居させている）。
      expect(
        find.descendant(
          of: find.byType(MusicView),
          matching: find.byTooltip('メニュー'),
        ),
        findsOneWidget,
      );

      // Drawer から home へ。IndexedStack は隠れている側の ☰ も木に持つので、
      // タップではなく Scaffold から開く。
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // home 側のレール見出しにも 'HOME' があるので、Drawer の中に限定する。
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('HOME')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(index(), 1);

      // 触っている間は戻らない。
      await tester.pump(const Duration(minutes: 2));
      await tester.tap(find.byType(HaSetupScreen));
      await tester.pump(const Duration(minutes: 2));
      expect(index(), 1);

      // 放っておくと戻る。
      await tester.pump(AppShell.idleTimeout + const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(index(), 0);
      home.dispose();
      music.dispose();
    });
  });

  testWidgets('アプリ全体が起動する（ENABLE_MUSIC の値に関わらず）', (tester) async {
    mockSecureStorage();
    await setSurface(tester, _ipad);

    await tester.pumpWidget(const HomeCtlApp());
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // music を落としたビルドでは IndexedStack ごと作らない。
    expect(
      find.byType(IndexedStack),
      AppFlags.enableMusic ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('make app-mock: 偽の HA で home のタイルが並ぶ', (tester) async {
    await setSurface(tester, _ipad);

    await tester.pumpWidget(const MockApp());
    await tester.pump(const Duration(milliseconds: 400));
    drainImageErrors(tester);

    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('HOME')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    drainImageErrors(tester);

    // 部屋は名前順なので、最初に開くのはキッチン。
    expect(find.text('キッチン'), findsOneWidget);
    expect(find.text('リビング'), findsOneWidget);
    expect(find.text('手元灯'), findsOneWidget);

    expect(find.widgetWithText(HomeTile, 'ケトル'), findsOneWidget);

    // 押した結果が画面に出るかは HomeScreen 側のテストで見ている。ここは
    // モックのエントリポイントが壊れていないことの確認に留める（枠を模す
    // FittedBox / MediaQuery 差し替えの中では、テスト上の座標が実機とずれる）。

    // アートワークが読めないと palette_generator が 15 秒のタイマーを残す。
    // 実機では起きないが、ここで消化しておかないとテストが落ちる。
    await tester.pump(const Duration(seconds: 16));
    drainImageErrors(tester);
  });
}

/// モックのアートワークは web/mock/*.png を HTTP で読む。テスト環境では必ず
/// 400 になるので、home の確認には関係ないぶんを捨てる。
void drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}
