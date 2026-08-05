import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Spotify Connect デバイスの `id → 表示名` を端末に残す。
///
/// **なぜ要るか。** Connect スピーカーは公式クライアントがバックエンドに
/// 登録するまで `/me/player/devices` の name が識別子のままで返ってくる
/// （`SpotifyDevice.looksLikeIdentifier` 参照）。一度でも本当の名前が返って
/// きたらそれを覚えておき、次に識別子が返ってきたときに当て直す。これで
/// 公式アプリで一度選びさえすれば、以後は再起動しても名前が出る。
///
/// 秘密ではないので本来 Keychain に置く必要は無いが、この app が持っている
/// ローカル保管はこれだけなので依存を増やさず相乗りする。
class DeviceNameCache {
  DeviceNameCache({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const _key = 'spotify_device_names';

  /// 増え続けないように上限を切る。溢れたら古い順に落とす
  /// （Map の挿入順＝最後に覚えた順を利用する）。
  static const _limit = 32;

  final FlutterSecureStorage _storage;

  Future<Map<String, String>> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (e) {
      // 壊れていても機能が一つ諦められるだけ。空で始める。
      debugPrint('DeviceNameCache.load failed: $e');
      return {};
    }
  }

  Future<void> save(Map<String, String> names) async {
    final trimmed = names.length <= _limit
        ? names
        : Map.fromEntries(names.entries.skip(names.length - _limit));
    try {
      await _storage.write(key: _key, value: jsonEncode(trimmed));
    } catch (e) {
      debugPrint('DeviceNameCache.save failed: $e');
    }
  }
}
