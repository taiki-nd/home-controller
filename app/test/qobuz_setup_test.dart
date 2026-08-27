import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/qobuz_models.dart';
import 'package:spotify_remote/models/wiim_models.dart';
import 'package:spotify_remote/services/qobuz_credentials.dart';
import 'package:spotify_remote/services/qobuz_web_login.dart';
import 'package:spotify_remote/services/wiim_credentials.dart';
import 'package:spotify_remote/services/wiim_discovery.dart';
import 'package:spotify_remote/state/qobuz_controller.dart';

import 'qobuz_support.dart';

/// 設定まわり——LAN 探索（§5.1）とアプリ内ブラウザからの取り込み（§3.2）。
void main() {
  ({
    QobuzController controller,
    FakeQobuzApi api,
    FakeQobuzCredentials credentials,
  })
  build({
    WiimDiscovery? discovery,
    QobuzAppConfig? app = testAppConfig,
    QobuzAccount? account = testAccount,
    WiimConnection? wiim = testWiim,
  }) {
    final api = FakeQobuzApi();
    final credentials = FakeQobuzCredentials(app: app, account: account);
    final controller = QobuzController(
      credentials: credentials,
      wiimCredentials: FakeWiimCredentials(wiim),
      api: api,
      wiim: FakeWiimApi(),
      discovery: discovery,
    );
    return (controller: controller, api: api, credentials: credentials);
  }

  group('WiiM の探索', () {
    test('見つかった順に候補が増え、進捗が 1 で終わる', () async {
      final discovery = WiimDiscovery(
        localAddresses: () async => ['192.168.1.10'],
        probe: (host) async =>
            host == '192.168.1.42' ? const WiimDevice(name: 'リビング') : null,
      );
      final (:controller, api: _, credentials: _) = build(discovery: discovery);
      addTearDown(controller.dispose);

      await controller.discoverWiim();

      expect(controller.scanning, isFalse);
      expect(controller.candidates.single.host, '192.168.1.42');
      expect(controller.candidates.single.label, 'リビング');
      expect(controller.scanProgress, 1);
      expect(controller.errorBanner, isNull);
    });

    test('0 台なら「見つからなかった」と言う（無音で終わらせない）', () async {
      final discovery = WiimDiscovery(
        localAddresses: () async => ['192.168.1.10'],
        probe: (host) async => null,
      );
      final (:controller, api: _, credentials: _) = build(discovery: discovery);
      addTearDown(controller.dispose);

      await controller.discoverWiim();

      expect(controller.candidates, isEmpty);
      expect(controller.errorBanner, contains('見つかりません'));
    });

    test('LAN が分からなければ手入力に倒す', () async {
      final discovery = WiimDiscovery(localAddresses: () async => const []);
      final (:controller, api: _, credentials: _) = build(discovery: discovery);
      addTearDown(controller.dispose);

      await controller.discoverWiim();

      expect(controller.errorBanner, contains('手で'));
    });

    test('選ぶと保存されて接続に行く', () async {
      final (:controller, api: _, credentials: _) = build();
      addTearDown(controller.dispose);
      await controller.start();

      await controller.selectWiim(
        const WiimCandidate(
          host: '192.168.1.99',
          device: WiimDevice(name: '寝室'),
        ),
      );

      expect(controller.wiimConnection?.host, '192.168.1.99');
      expect(controller.status, QobuzStatus.connected);
    });
  });

  group('アプリ内ブラウザからの取り込み', () {
    const result = QobuzWebLoginResult(
      appId: '798273057',
      token: 'web-token',
      secrets: ['はずれ', 'あたり'],
    );

    test('通る app_secret を選び、user_id を引き直して繋がる', () async {
      final (:controller, :api, :credentials) = build(app: null, account: null);
      addTearDown(controller.dispose);
      api.searchResults = QobuzSearchResults(tracks: [track(7)]);
      api.winningSecret = 'あたり';
      api.user = const QobuzUser(
        id: 1234,
        token: 'web-token',
        displayName: 'わたし',
        subscription: 'Studio',
      );
      await controller.start();
      expect(controller.status, QobuzStatus.needsSetup);

      await controller.applyWebLogin(result);

      expect(controller.appConfig?.appId, '798273057');
      expect(controller.appConfig?.appSecret, 'あたり');
      expect(controller.account?.userId, 1234);
      expect(credentials.account?.token, 'web-token');
      expect(controller.status, QobuzStatus.connected);
      expect(controller.busy, isFalse);
    });

    test('候補がどれも通らなくても、ログインだけは残す', () async {
      final (:controller, :api, :credentials) = build();
      addTearDown(controller.dispose);
      api.searchResults = QobuzSearchResults(tracks: [track(7)]);
      api.winningSecret = 'どれでもない';
      api.user = const QobuzUser(id: 1234, token: 'web-token');
      await controller.start();

      await controller.applyWebLogin(result);

      // 鍵は組で意味を持つので、通らなかったら前のまま戻す。
      expect(controller.appConfig, testAppConfig);
      expect(controller.errorBanner, contains('app_secret'));
      // **ここが肝。** 以前はトークンごと捨てていて、ブラウザでログイン
      // したのにもう一度ログインを求められていた。
      expect(controller.isSignedIn, isTrue);
      expect(credentials.account?.token, 'web-token');
      expect(controller.busy, isFalse);
    });

    test('まだ何も無いときは、通らなくても app_id だけ残す（検索は動く）', () async {
      final (:controller, :api, :credentials) = build(app: null, account: null);
      addTearDown(controller.dispose);
      api.searchResults = QobuzSearchResults(tracks: [track(7)]);
      api.winningSecret = 'どれでもない';
      api.user = const QobuzUser(id: 1234, token: 'web-token');
      await controller.start();

      await controller.applyWebLogin(result);

      expect(controller.appConfig?.appId, '798273057');
      expect(controller.appConfig?.appSecret, isEmpty);
      expect(controller.isSignedIn, isTrue);
      expect(credentials.account?.token, 'web-token');
      expect(controller.errorBanner, contains('app_secret'));
    });

    test('秘密が取れなくても、いまの app_secret のままトークンだけ入れ替える', () async {
      final (:controller, :api, credentials: _) = build();
      addTearDown(controller.dispose);
      await controller.start();

      await controller.applyWebLogin(
        const QobuzWebLoginResult(appId: '798273057', token: 'web-token'),
      );

      expect(controller.appConfig?.appId, '798273057');
      expect(controller.appConfig?.appSecret, testAppConfig.appSecret);
      expect(controller.account?.token, 'web-token');
      // 総当りに行っていない（確認用の 1 曲を引いていない）。
      expect(api.fileUrlCalls, isEmpty);
    });

    test('空の結果は握りつぶさずエラーにする', () async {
      final (:controller, api: _, credentials: _) = build();
      addTearDown(controller.dispose);
      await controller.start();

      await controller.applyWebLogin(
        const QobuzWebLoginResult(appId: '', token: ''),
      );

      expect(controller.errorBanner, isNotNull);
    });
  });
}
