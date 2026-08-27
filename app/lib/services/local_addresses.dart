/// 自分の LAN 上の IPv4 を数える口の差し替え。
///
/// **web ビルドを壊さないための条件付き import**（`insecure_adapter.dart` と
/// 同じ理由）。`NetworkInterface` は `dart:io` にしか無いので、
/// `make app-web` / `app-mock` の木からは stub 側が入る。
library;

export 'local_addresses_stub.dart'
    if (dart.library.io) 'local_addresses_io.dart';
