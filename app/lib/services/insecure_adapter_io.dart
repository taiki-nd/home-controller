import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// WiiM は自己署名証明書で待ち受けている（`docs/qobuz-wiim-integration.md` §5）。
///
/// **この [Dio] を Qobuz 側と共用しない。** 検証を切ってよいのは LAN 上の
/// WiiM に対してだけで、Qobuz への通信まで無防備にしてはいけない。
void allowSelfSignedCertificates(Dio dio) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient()
        // 壁掛けの LAN 相手なので、掴んだまま待たされるより早く諦める。
        ..connectionTimeout = const Duration(seconds: 5);
      client.badCertificateCallback = (cert, host, port) => true;
      return client;
    },
  );
}
