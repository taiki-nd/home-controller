import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

/// WebSocket の口だけを抜き出したもの。
///
/// テストで本物のソケットを立てずにプロトコルを検証したいので、
/// [HaSession] はこの型にしか触らない。
abstract class HaSocket {
  /// サーバーから届いたテキスト。閉じたら done する。
  Stream<String> get messages;

  void send(String data);

  Future<void> close();
}

/// 接続先から [HaSocket] を作る。テストでは差し替える。
typedef HaSocketOpener = Future<HaSocket> Function(Uri url);

/// `web_socket_channel` を [HaSocket] に被せたもの。
class WebSocketHaSocket implements HaSocket {
  WebSocketHaSocket(this._channel);

  static Future<HaSocket> open(Uri url) async {
    final channel = WebSocketChannel.connect(url);
    // ここで待たないと、接続できない相手でも send が黙って捨てられ、
    // 「反応しないが繋がっている」状態のまま固まる。
    await channel.ready;
    return WebSocketHaSocket(channel);
  }

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.map((event) => '$event');

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close(ws_status.normalClosure);
}
