import 'dart:convert';

import 'package:flutter/foundation.dart';

/// WiiM の `getPlayerStatus` / `getStatusEx` から、画面が使う分だけ持つ
/// （`docs/qobuz-wiim-integration.md` §4）。
///
/// **値はすべて文字列で返る。** 数値も `"52"` の形なので、素直に int で
/// 読もうとすると全部 null になる。

/// 再生状態。`status` フィールド。
enum WiimState {
  play,
  pause,
  stop,
  load,
  unknown;

  static WiimState parse(Object? raw) => switch (raw) {
    'play' => WiimState.play,
    'pause' => WiimState.pause,
    'stop' || 'none' => WiimState.stop,
    'load' => WiimState.load,
    _ => WiimState.unknown,
  };

  bool get isPlaying => this == WiimState.play;

  /// 曲が終わったと見なせる状態か。**`load` は含めない**——次の曲を掴んでいる
  /// 途中なので、ここで送ると二重に送ることになる。
  bool get isIdle => this == WiimState.stop || this == WiimState.unknown;
}

/// `getPlayerStatus` 1 回ぶん。
@immutable
class WiimStatus {
  const WiimStatus({
    required this.state,
    required this.position,
    required this.duration,
    required this.volume,
    required this.muted,
    this.title,
    this.artist,
    this.album,
    this.receivedAt,
  });

  final WiimState state;

  /// `curpos`。ミリ秒。
  final Duration position;

  /// `totlen`。ミリ秒。**ストリームによっては 0 で返る。**
  final Duration duration;

  /// `vol`。0-100。
  final int volume;

  final bool muted;

  /// **16 進エンコードされて返る**ので復号済みのものを持つ（§4）。
  final String? title;
  final String? artist;
  final String? album;

  /// 受け取った端末側の時刻。シークバーを毎秒進めるのに使う。
  final DateTime? receivedAt;

  bool get isPlaying => state.isPlaying;

  /// いまの再生位置。ポーリングの間を時計で埋める。
  ///
  /// **これをやらないとシークバーが 1 秒ごとにカクつく。** 再生中だけ、
  /// 受け取ってからの経過を足す（MA 側の `correctedElapsed` と同じ考え）。
  Duration correctedPosition(DateTime now) {
    final at = receivedAt;
    if (!isPlaying || at == null) return position;
    final delta = now.difference(at);
    if (delta.isNegative) return position;
    final corrected = position + delta;
    // 曲の長さを超えて進めない（終端で表示が飛ぶのを防ぐ）。
    if (duration > Duration.zero && corrected > duration) return duration;
    return corrected;
  }

  static WiimStatus fromJson(Map<String, dynamic> json, {DateTime? now}) =>
      WiimStatus(
        state: WiimState.parse(json['status']),
        position: Duration(milliseconds: _int(json['curpos'])),
        duration: Duration(milliseconds: _int(json['totlen'])),
        volume: _int(json['vol']).clamp(0, 100),
        muted: _int(json['mute']) == 1,
        title: decodeHex(json['Title']),
        artist: decodeHex(json['Artist']),
        album: decodeHex(json['Album']),
        receivedAt: now ?? DateTime.now(),
      );

  /// 曲名などは 16 進で返ることがある（`4142` → `AB`）。
  ///
  /// **常に 16 進とは限らない。** 素の文字列で返るファームもあるので、
  /// 16 進として読めないときはそのまま使う。`un_known` はメタデータ無しの
  /// 目印なので落とす。
  @visibleForTesting
  static String? decodeHex(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    if (raw == 'un_known' || raw == 'unknow') return null;
    final looksHex =
        raw.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(raw);
    if (!looksHex) return raw;
    try {
      final bytes = <int>[
        for (var i = 0; i < raw.length; i += 2)
          int.parse(raw.substring(i, i + 2), radix: 16),
      ];
      final text = utf8.decode(bytes, allowMalformed: false);
      return text.isEmpty ? null : text;
    } catch (e) {
      // 「たまたま 16 進に見えた普通の文字列」だった場合。
      return raw;
    }
  }

  static int _int(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }
}

/// `getStatusEx` のうち、接続確認で見たい分だけ。
@immutable
class WiimDevice {
  const WiimDevice({required this.name, this.firmware, this.model});

  final String name;
  final String? firmware;
  final String? model;

  static WiimDevice fromJson(Map<String, dynamic> json) => WiimDevice(
    name:
        json['DeviceName'] as String? ??
        json['device_name'] as String? ??
        'WiiM',
    firmware: json['firmware'] as String?,
    model: json['project'] as String? ?? json['hardware'] as String?,
  );
}
