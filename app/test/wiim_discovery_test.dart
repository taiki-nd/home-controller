import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/wiim_models.dart';
import 'package:spotify_remote/services/wiim_discovery.dart';

/// LAN 探索（`docs/qobuz-wiim-integration.md` §5.1）。
///
/// **ネットワークは触らない。** 舐めるホストの並べ方は純粋関数として切って
/// あり、叩く部分は差し替えられるようにしてある。
void main() {
  group('hostsToScan', () {
    test('自分の /24 を 1〜254 まで並べ、自分自身は外す', () {
      final hosts = WiimDiscovery.hostsToScan(['192.168.1.10']);
      expect(hosts.length, 253);
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
      expect(hosts, isNot(contains('192.168.1.10')));
      expect(hosts, isNot(contains('192.168.1.0')));
      expect(hosts, isNot(contains('192.168.1.255')));
    });

    test('プライベートアドレスだけを見る（VPN の 100.x などは無視）', () {
      final hosts = WiimDiscovery.hostsToScan([
        '100.64.3.2',
        '203.0.113.7',
        '10.0.0.5',
      ]);
      expect(hosts, contains('10.0.0.1'));
      expect(hosts.every((host) => host.startsWith('10.0.0.')), isTrue);
    });

    test('セグメントが多くても maxSubnets までしか舐めない', () {
      final hosts = WiimDiscovery.hostsToScan([
        '192.168.1.10',
        '192.168.2.10',
        '10.1.1.10',
      ]);
      expect(hosts.length, 253 * WiimDiscovery.maxSubnets);
      expect(hosts, isNot(contains('10.1.1.1')));
    });

    test('LAN が分からなければ何も舐めない（web / 権限なし）', () {
      expect(WiimDiscovery.hostsToScan(const []), isEmpty);
    });
  });

  group('scan', () {
    WiimDiscovery discoveryOver(
      List<String> addresses,
      Map<String, WiimDevice> devices, {
      List<String>? probed,
    }) => WiimDiscovery(
      localAddresses: () async => addresses,
      probe: (host) async {
        probed?.add(host);
        return devices[host];
      },
    );

    test('見つかったものだけ返し、そのつど onFound を呼ぶ', () async {
      final found = <String>[];
      final discovery = discoveryOver(
        ['192.168.1.10'],
        {
          '192.168.1.42': const WiimDevice(name: 'リビング', model: 'WiiM Pro'),
          '192.168.1.99': const WiimDevice(name: '寝室'),
        },
      );
      final candidates = await discovery.scan(
        onFound: (candidate) => found.add(candidate.host),
      );
      expect(
        candidates.map((c) => c.host),
        containsAll(<String>['192.168.1.42', '192.168.1.99']),
      );
      expect(candidates, hasLength(2));
      expect(found, hasLength(2));
    });

    test('進捗は最後に「全部見た」で終わる', () async {
      var last = (0, 0);
      final discovery = discoveryOver(['192.168.1.10'], const {});
      await discovery.scan(onProgress: (done, total) => last = (done, total));
      expect(last, (253, 253));
    });

    test('cancel すると途中で止まる', () async {
      final probed = <String>[];
      late final WiimDiscovery discovery;
      discovery = WiimDiscovery(
        localAddresses: () async => ['192.168.1.10'],
        concurrency: 1,
        probe: (host) async {
          probed.add(host);
          if (probed.length >= 5) discovery.cancel();
          return null;
        },
      );
      await discovery.scan();
      expect(probed.length, lessThan(253));
    });

    test('1 台転んでも走査は続く', () async {
      final discovery = WiimDiscovery(
        localAddresses: () async => ['192.168.1.10'],
        probe: (host) async {
          if (host == '192.168.1.1') throw StateError('壊れた応答');
          if (host == '192.168.1.42') return const WiimDevice(name: 'リビング');
          return null;
        },
      );
      final candidates = await discovery.scan();
      expect(candidates.single.host, '192.168.1.42');
    });
  });
}
