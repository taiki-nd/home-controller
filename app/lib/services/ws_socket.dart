import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

/// WebSocket の口だけを抜き出したもの。
///
/// テストで本物のソケットを立てずにプロトコルを検証したいので、
/// [HaSession] と [MaSession] はこの型にしか触らない。
///
/// 元は `ha_socket.dart` に `HaSocket` として置いていたが、HA と MA の
/// 2 つのセッションが同じ口を使うので中立な名前でここへ移した。
/// `ha_socket.dart` は typedef で残してある。
abstract class AppSocket {
  /// サーバーから届いたテキスト。閉じたら done する。
  Stream<String> get messages;

  void send(String data);

  Future<void> close();
}

/// 接続先から [AppSocket] を作る。テストでは差し替える。
typedef SocketOpener = Future<AppSocket> Function(Uri url);

/// `web_socket_channel` を [AppSocket] に被せたもの。
class ChannelSocket implements AppSocket {
  ChannelSocket(this._channel);

  static Future<AppSocket> open(Uri url) async {
    final channel = WebSocketChannel.connect(url);
    // ここで待たないと、接続できない相手でも send が黙って捨てられ、
    // 「反応しないが繋がっている」状態のまま固まる。
    await channel.ready;
    return ChannelSocket(channel);
  }

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.map((event) => '$event');

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close(ws_status.normalClosure);
}
