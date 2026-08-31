import AVFoundation
import Flutter
import UIKit

/// 別のアプリを開いている間もアプリを生かしておく口（issue #8）。
///
/// **鳴っているのは WiiM で、この端末ではない。** それでも端末側のアプリが
/// 生きていないとキューが進まない——曲の終わりを見て次を投げるのも、次の 1 曲を
/// 本体に預け直すのも、アプリが動いていて初めてできる。
///
/// iOS はバックグラウンドに入ったアプリを数十秒で suspend し、そうなると
/// Dart の `Timer` も止まる。生き続けるには `UIBackgroundModes` が要るが、
/// LAN の機器を見張るための口は無い（`fetch` / `processing` は起こされる間隔が
/// 曲の切れ目に全く合わない）。実用になるのは `audio` だけで、これは
/// **アプリ自身が音を出していること**が条件なので、無音を鳴らし続ける。
///
/// **他のアプリの音は邪魔しない。** `.mixWithOthers` を付けているので、
/// ダッキングも中断も起こさない。
class PlaybackKeepAlive: NSObject, FlutterPlugin {
  private static let channelName = "app.home-ctl/keepalive"

  private var player: AVAudioPlayer?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = PlaybackKeepAlive()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      result(start())
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 無音を回し始める。すでに回っていれば何もしない。
  private func start() -> Bool {
    if player?.isPlaying == true { return true }
    do {
      let session = AVAudioSession.sharedInstance()
      // **`.playback` でなければバックグラウンドで鳴り続けない。**
      // `.mixWithOthers` は他アプリの音を止めないため。
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)

      let player = try AVAudioPlayer(data: PlaybackKeepAlive.silentWav())
      // -1 で無限ループ。**曲の切れ目で一瞬でも止めない**——セッションが
      // 空いた隙に iOS が suspend してくる。
      player.numberOfLoops = -1
      player.volume = 0
      player.prepareToPlay()
      player.play()
      self.player = player

      // 電話などで中断されたら、終わり次第かけ直す。**戻さないとそこで
      // suspend され、次の曲へ進まなくなる。**
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleInterruption(_:)),
        name: AVAudioSession.interruptionNotification, object: session)
      return true
    } catch {
      NSLog("PlaybackKeepAlive: 無音を回せませんでした (\(error))")
      player = nil
      return false
    }
  }

  private func stop() {
    NotificationCenter.default.removeObserver(
      self, name: AVAudioSession.interruptionNotification, object: nil)
    player?.stop()
    player = nil
    // **他のアプリに「空いた」と伝えてから降りる。** これが無いと、
    // 止めていた音楽アプリが鳴り直さないことがある。
    try? AVAudioSession.sharedInstance().setActive(
      false, options: [.notifyOthersOnDeactivation])
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    guard type == .ended else { return }
    try? AVAudioSession.sharedInstance().setActive(true)
    player?.play()
  }

  /// 無音の WAV を組む。
  ///
  /// **アセットとして持たない。** Runner ターゲットにバイナリを 1 つ足すと
  /// project.pbxproj に手が入り、生成物との差分が読みにくくなる。数十バイトの
  /// ヘッダなので、その場で組んだほうが読める。
  ///
  /// 8kHz / モノラル / 16bit の 1 秒。`numberOfLoops = -1` で回し続ける。
  private static func silentWav() -> Data {
    let sampleRate = 8000
    let channels = 1
    let bitsPerSample = 16
    let dataSize = sampleRate * channels * bitsPerSample / 8  // 1 秒ぶん
    let byteRate = sampleRate * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8

    var data = Data()
    func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func append32(_ value: Int) {
      var le = UInt32(value).littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    func append16(_ value: Int) {
      var le = UInt16(value).littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    append("RIFF")
    append32(36 + dataSize)
    append("WAVE")
    append("fmt ")
    append32(16)  // PCM のヘッダ長
    append16(1)  // PCM
    append16(channels)
    append32(sampleRate)
    append32(byteRate)
    append16(blockAlign)
    append16(bitsPerSample)
    append("data")
    append32(dataSize)
    data.append(Data(count: dataSize))  // 全部 0 = 無音
    return data
  }
}
