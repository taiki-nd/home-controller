import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/wiim_api.dart';
import 'package:spotify_remote/services/wiim_credentials.dart';
import 'package:spotify_remote/services/wiim_upnp.dart';

/// UPnP が断られたあとの倒し方（`docs/qobuz-wiim-integration.md` §5.5）。
///
/// **倒れっぱなしにしない。** HTTP API に落ちている間、WiiM 本体の画面は
/// 署名付き URL と既定のジャケットに戻る。一度の取りこぼし（本体の再起動中、
/// スリープ復帰直後、Wi-Fi の瞬断）でアプリを立ち上げ直すまでそのまま、
/// という状態を作らないための固定。
class _DeniedUpnp extends WiimUpnp {
  _DeniedUpnp() : super(connection: const WiimConnection(host: '192.168.1.42'));

  int calls = 0;

  /// 立てると通るようになる。**本体が戻ってきた**状況の再現。
  bool healthy = false;

  @override
  Future<void> play(String url, WiimTrackMetadata meta) async {
    calls += 1;
    if (!healthy) throw WiimUpnpException('受け付けませんでした');
  }

  @override
  void close() {}
}

class _OkAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString('OK', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const meta = WiimTrackMetadata(title: '曲', artist: 'アーティスト');
  const url = 'https://streaming.qobuz.com/file/1.flac?sig=abc';

  ({WiimApi api, _DeniedUpnp upnp, _OkAdapter http}) subject() {
    final upnp = _DeniedUpnp();
    final http = _OkAdapter();
    final dio = Dio()..httpClientAdapter = http;
    final api = WiimApi(
      connection: const WiimConnection(host: '192.168.1.42'),
      dio: dio,
      upnp: upnp,
    );
    return (api: api, upnp: upnp, http: http);
  }

  test('UPnP が断られたら HTTP API に落ちる', () async {
    final s = subject();

    final route = await s.api.play(url, meta: meta);

    expect(route, WiimPlayRoute.httpApi);
    expect(s.upnp.calls, 1);
    expect(
      s.http.requests.single.uri.toString(),
      contains('setPlayerCmd:play'),
    );
  });

  test('断られた直後は試し直さない（曲送りのたびに待たされない）', () async {
    final s = subject();
    final at = DateTime(2026, 8, 28, 12);

    await s.api.play(url, meta: meta, now: at);
    await s.api.play(url, meta: meta, now: at.add(const Duration(seconds: 30)));

    // 2 曲目は UPnP を叩かずに落とす。
    expect(s.upnp.calls, 1);
  });

  test('間を空ければ試し直し、通れば UPnP に戻る', () async {
    final s = subject();
    final at = DateTime(2026, 8, 28, 12);

    await s.api.play(url, meta: meta, now: at);
    expect(s.api.upnpDenied, isTrue);

    s.upnp.healthy = true;
    final route = await s.api.play(
      url,
      meta: meta,
      now: at.add(const Duration(minutes: 3)),
    );

    expect(route, WiimPlayRoute.upnp);
    expect(s.upnp.calls, 2);
    // **戻ったら覚えを捨てる。** 次に落ちたときまた 2 分待つのが正しい。
    expect(s.api.upnpDenied, isFalse);
  });

  test('接続先を入れ替えたら諦めを捨てる', () async {
    final s = subject();
    final at = DateTime(2026, 8, 28, 12);

    await s.api.play(url, meta: meta, now: at);
    s.api.connection = const WiimConnection(host: '192.168.1.99');

    expect(s.api.upnpDenied, isFalse);

    s.upnp.healthy = true;
    final route = await s.api.play(url, meta: meta, now: at);

    expect(route, WiimPlayRoute.upnp);
  });
}
