import 'package:dio/dio.dart';

/// web 版。**ブラウザからは証明書検証を切れない。**
///
/// そもそも web から WiiM は叩けない（自己署名 + 混在コンテンツ + CORS）ので、
/// ここは `main_mock.dart` をブラウザで動かすためだけの空実装。
void allowSelfSignedCertificates(Dio dio) {}
