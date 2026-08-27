import 'dart:io';

import 'package:flutter/foundation.dart';

/// 端末が持っている IPv4 を並べる（`WiimDiscovery` が /24 を割り出すため）。
///
/// **ループバックとリンクローカルは外す。** 169.254.x.x を混ぜると
/// 誰も居ないセグメントを 254 回叩きに行くことになる。
Future<List<String>> localIPv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ];
  } on SocketException catch (e) {
    // iOS でローカルネットワークの許可が無いと here で転ぶことがある。
    // 探索を諦めるだけで、IP 手入力の道は残る。
    debugPrint('localIPv4Addresses failed: $e');
    return const [];
  }
}
