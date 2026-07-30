import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/spotify_config.dart';
import 'package:spotify_remote/theme/tokens.dart';
import 'package:spotify_remote/ui/login_screen.dart';
import 'package:spotify_remote/ui/widgets/atoms.dart';

void main() {
  testWidgets('ログイン画面が描画される', (tester) async {
    final auth = AuthService();
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: LoginScreen(auth: auth)),
    );

    expect(find.text('Everyone adds\nthe next track.'), findsOneWidget);
    expect(find.text('POWERED BY SPOTIFY'), findsOneWidget);

    // Client ID 未設定のビルドでは Connect ボタンではなく設定案内を出す。
    if (SpotifyConfig.isConfigured) {
      expect(find.text('Connect with Spotify'), findsOneWidget);
    } else {
      expect(find.text('SETUP REQUIRED'), findsOneWidget);
    }
  });

  testWidgets('シャッフルのトグルが値を返す', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ShuffleSwitch(value: value, onChanged: (v) => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ShuffleSwitch));
    expect(value, isTrue);
  });

  test('formatDuration は m:ss', () {
    expect(formatDuration(const Duration(seconds: 5)), '0:05');
    expect(formatDuration(const Duration(minutes: 4, seconds: 3)), '4:03');
    expect(formatDuration(const Duration(minutes: 12, seconds: 30)), '12:30');
    expect(formatDuration(Duration.zero), '0:00');
  });
}
