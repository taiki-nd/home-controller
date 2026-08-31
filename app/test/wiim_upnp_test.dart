import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/wiim_credentials.dart';
import 'package:spotify_remote/services/wiim_upnp.dart';

/// 投げた SOAP をそのまま取っておく口。
class _Capture implements HttpClientAdapter {
  final bodies = <String>[];
  final actions = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    bodies.add(options.data as String);
    actions.add(options.headers['SOAPACTION'] as String);
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

/// WiiM 本体のディスプレイに出す見出しの組み立て
/// （`docs/qobuz-wiim-integration.md` §5.5）。
///
/// **ここが崩れると Ultra の画面に署名付き URL が出る。** 実機で当たりを
/// 確かめた形をそのまま固定しておく。
void main() {
  const signedUrl =
      'https://streaming-qobuz-std.akamaized.net/file'
      '?uid=1&eid=2&fmt=6&hmac=abc';

  test('曲名・アーティスト・アルバム・ジャケットが全部入る', () {
    final didl = WiimUpnp.buildDidl(
      signedUrl,
      const WiimTrackMetadata(
        title: 'Clair de Lune',
        artist: 'Claude Debussy',
        album: 'Suite bergamasque',
        artUrl: 'https://static.qobuz.com/images/covers/ab/cd/xyz_600.jpg',
        duration: Duration(minutes: 5, seconds: 3),
        mimeType: 'audio/flac',
      ),
    );

    expect(didl, contains('<dc:title>Clair de Lune</dc:title>'));
    // **`dc:creator` と `upnp:artist` は両方要る。** 片方だけの機種向けの保険。
    expect(didl, contains('<dc:creator>Claude Debussy</dc:creator>'));
    expect(didl, contains('<upnp:artist>Claude Debussy</upnp:artist>'));
    expect(didl, contains('<upnp:album>Suite bergamasque</upnp:album>'));
    expect(
      didl,
      contains(
        '<upnp:albumArtURI>'
        'https://static.qobuz.com/images/covers/ab/cd/xyz_600.jpg'
        '</upnp:albumArtURI>',
      ),
    );
    // 実機が返すのと同じゼロ埋めの形に揃える。
    expect(didl, contains('duration="00:05:03"'));
    expect(didl, contains('protocolInfo="http-get:*:audio/flac:*"'));
  });

  test('署名付き URL の & は DIDL の中でエスケープされる', () {
    final didl = WiimUpnp.buildDidl(
      signedUrl,
      const WiimTrackMetadata(title: 'x'),
    );

    // 生の `&` が残ると DIDL 自体が壊れた XML になり、WiiM は丸ごと捨てる。
    expect(didl, contains('uid=1&amp;eid=2&amp;fmt=6&amp;hmac=abc'));
    expect(didl.contains('&eid'), isFalse);
  });

  test('SOAP に載せる時点でもう一段エスケープされる', () {
    final didl = WiimUpnp.buildDidl(
      signedUrl,
      const WiimTrackMetadata(title: 'x'),
    );
    final escaped = WiimUpnp.escapeXml(didl);

    // DIDL は SOAP の中に「文字列として」入るので 2 重になる（§5.5）。
    expect(escaped, contains('uid=1&amp;amp;eid=2'));
    expect(escaped, contains('&lt;dc:title&gt;x&lt;/dc:title&gt;'));
  });

  test('無い項目は要素ごと落とす', () {
    final didl = WiimUpnp.buildDidl(
      signedUrl,
      // アーティスト不明・ジャケット無し。空文字も同じ扱い。
      const WiimTrackMetadata(title: 'x', artist: '  ', album: null),
    );

    // **空要素を出すと WiiM は `unknow` を返して画面にもそう出る。**
    expect(didl.contains('upnp:artist'), isFalse);
    expect(didl.contains('upnp:album'), isFalse);
    expect(didl.contains('albumArtURI'), isFalse);
  });

  test('長さが分からなければ duration を付けない', () {
    final didl = WiimUpnp.buildDidl(
      signedUrl,
      const WiimTrackMetadata(title: 'x'),
    );

    expect(didl.contains('duration='), isFalse);
    // mime が分からないときは FLAC 前提で置く（hi-res 用途なので）。
    expect(didl, contains('audio/flac'));
  });

  /// 次の 1 曲の預け方（issue #8）。
  ///
  /// **引数名は `SetAVTransportURI` と違う。** あちらは `CurrentURI` /
  /// `CurrentURIMetaData`、こちらは `NextURI` / `NextURIMetaData`。実機の
  /// `rendertransportSCPD.xml` がそう宣言していて、綴りを間違えると 402
  /// (Invalid Args) で黙って落ちる。
  group('SetNextAVTransportURI', () {
    ({WiimUpnp upnp, _Capture http}) subject() {
      final http = _Capture();
      final dio = Dio()..httpClientAdapter = http;
      final upnp = WiimUpnp(
        connection: const WiimConnection(host: '192.168.1.42'),
        dio: dio,
      );
      return (upnp: upnp, http: http);
    }

    test('NextURI と NextURIMetaData で送る', () async {
      final s = subject();

      await s.upnp.setNext(
        signedUrl,
        const WiimTrackMetadata(title: 'Clair de Lune', artist: 'Debussy'),
      );

      expect(
        s.http.actions.single,
        '"urn:schemas-upnp-org:service:AVTransport:1#SetNextAVTransportURI"',
      );
      final body = s.http.bodies.single;
      expect(body, contains('<NextURI>'));
      expect(body, contains('<NextURIMetaData>'));
      // `CurrentURI` と取り違えていない。
      expect(body.contains('CurrentURI'), isFalse);
      // DIDL は SOAP の中で 2 重にエスケープされる（§5.5）。
      expect(body, contains('uid=1&amp;amp;eid=2'));
      expect(body, contains('&lt;dc:title&gt;Clair de Lune&lt;/dc:title&gt;'));
    });

    test('取り下げは空の NextURI を送る', () async {
      final s = subject();

      await s.upnp.clearNext();

      expect(s.http.bodies.single, contains('<NextURI></NextURI>'));
    });

    test('Play は送らない（いま鳴っているものに触らない）', () async {
      final s = subject();

      await s.upnp.setNext(signedUrl, const WiimTrackMetadata(title: 'x'));

      // **予約するだけ。** ここで Play を送ると、いま鳴っている曲を止めて
      // 頭から鳴らし直してしまう。
      expect(s.http.actions.length, 1);
    });
  });
}
