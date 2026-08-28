import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/services/wiim_upnp.dart';

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
}
