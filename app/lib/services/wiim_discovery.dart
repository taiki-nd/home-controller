import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/wiim_models.dart';
import 'insecure_adapter.dart';
import 'local_addresses.dart';
import 'wiim_credentials.dart';

/// 見つかった 1 台。
@immutable
class WiimCandidate {
  const WiimCandidate({required this.host, required this.device});

  final String host;
  final WiimDevice device;

  WiimConnection get connection => WiimConnection(host: host);

  /// 一覧の見出し。名前を付けていない個体は機種名で出す。
  String get label =>
      device.name.isEmpty ? (device.model ?? 'WiiM') : device.name;

  @override
  bool operator ==(Object other) =>
      other is WiimCandidate && other.host == host;

  @override
  int get hashCode => host.hashCode;
}

/// ホスト 1 つを叩いて「WiiM だったか」を返す口。テストで差し替える。
typedef WiimProbe = Future<WiimDevice?> Function(String host);

/// 同じ LAN から WiiM を探す（`docs/qobuz-wiim-integration.md` §5.1）。
///
/// **SSDP でも mDNS でもなく、/24 を端から叩く。** iOS でマルチキャストを
/// 使うには `com.apple.developer.networking.multicast` が要り、Apple の申請と
/// 承認が要る。ユニキャストの HTTP なら `NSLocalNetworkUsageDescription` だけで
/// 済み、権限の取りこぼしもタイムアウトではなく「0 台」という形で見える。
///
/// 叩くのは `getStatusEx`（`WiimApi` と同じ自己署名証明書つき HTTPS）。
/// **他人の家電を長く待たない**ように、1 台あたりの待ちは 1.2 秒で切る。
class WiimDiscovery {
  WiimDiscovery({
    WiimProbe? probe,
    Future<List<String>> Function()? localAddresses,
    this.concurrency = 24,
  }) : _probe = probe,
       _localAddresses = localAddresses ?? localIPv4Addresses;

  /// 1 台あたりの待ち。**LAN 相手なので短くてよい。**
  /// 居ないアドレスは接続拒否で即返り、居るのに黙っている相手だけがここまで待つ。
  static const probeTimeout = Duration(milliseconds: 1200);

  /// 舐めるセグメントの上限。VPN や Docker で複数刺さっていることがあるので、
  /// **全部は舐めない**（254 × n 回になる）。
  static const maxSubnets = 2;

  final WiimProbe? _probe;
  final Future<List<String>> Function() _localAddresses;

  /// 同時に投げる数。上げすぎるとファイルディスクリプタが尽きる。
  final int concurrency;

  Dio? _dio;
  bool _cancelled = false;

  /// 走査中に画面を閉じたときに止める口。
  void cancel() => _cancelled = true;

  /// 探す。見つかるそばから [onFound] を呼び、最後に見つかった順で返す。
  ///
  /// **投げっぱなしにしない。** [onProgress] で「254 台中 120 台まで見た」を
  /// 出せるようにしてあるのは、無音で 10 秒待たされると壊れて見えるため。
  Future<List<WiimCandidate>> scan({
    void Function(WiimCandidate candidate)? onFound,
    void Function(int done, int total)? onProgress,
  }) async {
    _cancelled = false;
    final hosts = hostsToScan(await _localAddresses());
    onProgress?.call(0, hosts.length);
    if (hosts.isEmpty) return const [];

    final probe = _probe ?? _defaultProbe;
    final found = <WiimCandidate>[];
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled) return;
        final index = next++;
        if (index >= hosts.length) return;
        final host = hosts[index];
        WiimDevice? device;
        try {
          device = await probe(host);
        } catch (_) {
          // 1 台転んでも走査は続ける（証明書も応答も当てにならない相手）。
          device = null;
        }
        done += 1;
        if (_cancelled) return;
        onProgress?.call(done, hosts.length);
        if (device == null) continue;
        final candidate = WiimCandidate(host: host, device: device);
        found.add(candidate);
        onFound?.call(candidate);
      }
    }

    final workers = concurrency < hosts.length ? concurrency : hosts.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return List.unmodifiable(found);
  }

  /// 自分の IPv4 から「舐めるべきホスト」を並べる。**純粋関数**——
  /// ここがいちばん間違えやすいので、テストで固定の入力から検証する。
  ///
  /// - プライベートアドレス（10 / 172.16-31 / 192.168）だけを対象にする
  /// - /24 とみなして `.1`〜`.254` を並べる（家庭の LAN はこれで足りる）
  /// - 自分自身と `.0` / `.255` は外す
  static List<String> hostsToScan(Iterable<String> localAddresses) {
    final prefixes = <String>[];
    final self = <String>{};
    for (final address in localAddresses) {
      final octets = address.split('.');
      if (octets.length != 4) continue;
      if (!_isPrivate(octets)) continue;
      self.add(address);
      final prefix = octets.take(3).join('.');
      if (!prefixes.contains(prefix)) prefixes.add(prefix);
      if (prefixes.length >= maxSubnets) break;
    }
    return [
      for (final prefix in prefixes)
        for (var host = 1; host <= 254; host++)
          if (!self.contains('$prefix.$host')) '$prefix.$host',
    ];
  }

  static bool _isPrivate(List<String> octets) {
    final first = int.tryParse(octets[0]);
    final second = int.tryParse(octets[1]);
    if (first == null || second == null) return false;
    if (first == 10) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    if (first == 192 && second == 168) return true;
    return false;
  }

  /// 既定の叩き方。`WiimApi` と同じ URL・同じ自己署名証明書の扱い。
  ///
  /// **Qobuz 用の [Dio] とは共用しない**（検証を切ってあるため）。
  Future<WiimDevice?> _defaultProbe(String host) async {
    final dio = _dio ??= _createDio();
    try {
      // **自前でも打ち切る。** 自己署名を通すために `HttpClient` を差して
      // いるので、dio の connectTimeout だけに任せると掴んだまま待つ経路が残る。
      final response = await dio
          .getUri<String>(WiimConnection(host: host).commandUrl('getStatusEx'))
          .timeout(probeTimeout);
      final body = response.data ?? '';
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      // **LinkPlay かどうかを見る。** 同じ LAN の別の HTTPS 機器が
      // たまたま JSON を返すことはあるので、getStatusEx らしさで絞る。
      if (!json.containsKey('DeviceName')) return null;
      if (!json.containsKey('uuid') &&
          !json.containsKey('project') &&
          !json.containsKey('firmware')) {
        return null;
      }
      return WiimDevice.fromJson(json);
    } catch (_) {
      // 居ない・黙っている・JSON でない。ぜんぶ「WiiM ではない」でよい。
      return null;
    }
  }

  Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: probeTimeout,
        receiveTimeout: probeTimeout,
        sendTimeout: probeTimeout,
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    allowSelfSignedCertificates(dio);
    return dio;
  }

  void close() {
    _cancelled = true;
    _dio?.close(force: true);
    _dio = null;
  }
}
