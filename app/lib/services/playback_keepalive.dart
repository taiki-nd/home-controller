import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 別のアプリを開いている間もアプリを生かしておく口（issue #8）。
///
/// **鳴っているのは WiiM で、この端末ではない。** それでも端末側のアプリが
/// 生きていないとキューは進まない——曲の終わりを見て次を投げるのも、次の 1 曲を
/// 本体に預け直すのも、アプリが動いていて初めてできる
/// （`docs/qobuz-wiim-integration.md` §5.3）。
///
/// 実体は iOS 側の `PlaybackKeepAlive.swift`（無音を鳴らし続けて
/// `UIBackgroundModes: audio` を成立させる）。**iOS 以外では何もしない。**
/// Android は今のところ配っておらず、web には概念自体が無い。
class PlaybackKeepAlive {
  PlaybackKeepAlive({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_name);

  static const _name = 'app.home-ctl/keepalive';

  final MethodChannel _channel;

  bool _active = false;

  /// いま生き延びる仕掛けが回っているか。
  bool get isActive => _active;

  /// この端末で使えるか。
  ///
  /// **`kIsWeb` を先に見る。** web では `defaultTargetPlatform` が
  /// iOS を返すことがある（Safari から開いたとき）。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// 無音を回し始める。すでに回っていれば何もしない。
  Future<void> start() async {
    if (_active || !isSupported) return;
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      _active = ok ?? false;
    } on PlatformException catch (e) {
      // **黙って諦める。** 回せなくても「前面にいる間は今までどおり」に
      // 戻るだけで、画面に出すほどの異常ではない。
      debugPrint('PlaybackKeepAlive.start failed: $e');
      _active = false;
    } on MissingPluginException {
      // ホットリスタート直後などに起こりうる。次の機会に効けばよい。
      _active = false;
    }
  }

  /// 前面に戻ったら降りる。**音声セッションを掴んだままにしない。**
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      debugPrint('PlaybackKeepAlive.stop failed: $e');
    } on MissingPluginException {
      // 何も回っていなかったということ。
    }
  }
}
