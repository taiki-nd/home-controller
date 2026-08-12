import 'ws_socket.dart';

export 'ws_socket.dart' show AppSocket, SocketOpener, ChannelSocket;

/// HA 用の別名。中身は `ws_socket.dart`（MA と共用）。
///
/// MA を足すときに口を共通化したが、HA 側の呼び出しとテストを触らずに
/// 済ませるため名前はここに残してある。
typedef HaSocket = AppSocket;

/// 接続先から [HaSocket] を作る。テストでは差し替える。
typedef HaSocketOpener = SocketOpener;

/// `web_socket_channel` を [HaSocket] に被せたもの。
typedef WebSocketHaSocket = ChannelSocket;
