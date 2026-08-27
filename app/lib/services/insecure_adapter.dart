/// 自己署名証明書を通す口の差し替え。
///
/// **web ビルドを壊さないための条件付き import。** `lib/main_mock.dart` は
/// `AppShell` ごとブラウザで動かすので、この木から `dart:io` を直接
/// 参照すると `make app-mock` / `app-web` が通らなくなる。
library;

export 'insecure_adapter_stub.dart'
    if (dart.library.io) 'insecure_adapter_io.dart';
