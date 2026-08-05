import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';
import 'package:spotify_remote/services/auth_service.dart';
import 'package:spotify_remote/services/device_name_cache.dart';
import 'package:spotify_remote/services/spotify_api.dart';
import 'package:spotify_remote/state/player_controller.dart';

/// Connect スピーカーは公式クライアントがバックエンドに登録するまで、
/// `/me/player/devices` の name が識別子のまま返ってくる。一度でも本名が
/// 返ってきたら覚えておき、次からは当て直す — その往復をここで固定する。
const _wiimId = '0123456789abcdef0123456789abcdef01234567';

class FakeDeviceApi extends SpotifyApi {
  FakeDeviceApi() : super(AuthService());

  /// null なら「Spotify がまだ表示名を持っていない」状態。
  String? deviceName = _wiimId;

  @override
  Future<List<SpotifyDevice>> devices() async => [
    SpotifyDevice.fromJson({
      'id': _wiimId,
      'name': deviceName,
      'type': 'Speaker',
      'is_active': true,
    })!,
  ];

  @override
  Future<PlaybackState> playbackState() async => PlaybackState.stopped;

  @override
  Future<QueueSnapshot> queue() async => QueueSnapshot.empty;

  @override
  Future<List<PlaylistSummary>> playlists({int limit = 50}) async => const [];

  @override
  Duration? get rateLimitCooldown => null;
}

/// Keychain の代わり。端末をまたいだ再起動は、同じ中身で作り直して表す。
class InMemoryStorage extends FlutterSecureStorage {
  const InMemoryStorage(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  test('名前が識別子のうちは Unknown、本名が来たら覚えて次から出す', () async {
    final disk = <String, String>{};
    final api = FakeDeviceApi();

    final first = PlayerController(
      api,
      deviceNames: DeviceNameCache(storage: InMemoryStorage(disk)),
    );
    await first.start();

    // 初回。Spotify は識別子しか返していないので名前は出せない。
    expect(first.devices.single.name, 'Unknown device');
    expect(first.deviceLabel, 'Unknown device');
    expect(disk, isEmpty);

    // 公式アプリでデバイスを選ぶと、以降は本名が返るようになる。
    api.deviceName = 'WiiM Ultra';
    await first.refreshDevices();
    expect(first.deviceLabel, 'WiiM Ultra');
    expect(disk, isNotEmpty);
    first.dispose();

    // 再起動。Spotify がまた識別子に戻っても、覚えた名前を当てる。
    api.deviceName = _wiimId;
    final second = PlayerController(
      api,
      deviceNames: DeviceNameCache(storage: InMemoryStorage(disk)),
    );
    await second.start();
    expect(second.deviceLabel, 'WiiM Ultra');
    second.dispose();
  });

  test('キャッシュを渡さなければ何も書かない', () async {
    final api = FakeDeviceApi()..deviceName = 'WiiM Ultra';
    final controller = PlayerController(api);
    await controller.start();
    expect(controller.deviceLabel, 'WiiM Ultra');
    controller.dispose();
  });

  test('保存は上限で頭から捨てる', () async {
    final disk = <String, String>{};
    final cache = DeviceNameCache(storage: InMemoryStorage(disk));
    await cache.save({
      for (var i = 0; i < 40; i++) 'id$i': 'name$i',
    });
    final loaded = await cache.load();
    expect(loaded.length, 32);
    expect(loaded.containsKey('id7'), isFalse);
    expect(loaded['id39'], 'name39');
  });
}
