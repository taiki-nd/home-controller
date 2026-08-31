import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'wiim_credentials.dart';

/// WiiM に渡す曲の見出し（`docs/qobuz-wiim-integration.md` §5.5）。
///
/// **HTTP API の `setPlayerCmd:play:<url>` には、これを載せる口が無い。**
/// その経路で送ると WiiM は URL をそのまま `dc:title` に詰め、アーティスト・
/// アルバム・ジャケットは空のまま残る（実機で確認済み）。UPnP の
/// `SetAVTransportURI` に DIDL-Lite を添えて送ると、同じ枠がちゃんと埋まる。
@immutable
class WiimTrackMetadata {
  const WiimTrackMetadata({
    required this.title,
    this.artist,
    this.album,
    this.artUrl,
    this.duration,
    this.mimeType,
  });

  final String title;
  final String? artist;
  final String? album;

  /// ジャケットの URL。**WiiM 本体が自分で取りに行く**ので、端末からでは
  /// なく WiiM から届く先である必要がある。Qobuz の `static.qobuz.com` は
  /// https のまま通ることを実機で確認した。
  final String? artUrl;

  final Duration? duration;

  /// `track/getFileUrl` の `mime_type`。`<res protocolInfo>` に載せる。
  final String? mimeType;
}

/// 再生指示がどの経路で通ったか。
///
/// 署名付き URL の載せ方（§5.2）を試し直すかどうかの判断に使う。UPnP は
/// SOAP の中に XML として入るのでエスケープの当たり外れが無く、通った時点で
/// 載せ方を疑う必要が消える。
enum WiimPlayRoute { upnp, httpApi }

/// WiiM の UPnP AVTransport（`http://<host>:49152`）。
///
/// **HTTP API とは別ポート・別プロトコル。** 自己署名 https の httpapi.asp と
/// 違って素の http なので、証明書検証を切った [Dio] を持ち込んではいけない。
class WiimUpnp {
  WiimUpnp({this.connection, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 8),
              responseType: ResponseType.plain,
            ),
          );

  /// UPnP の待ち口。LinkPlay 系はどの機種もここ。
  static const port = 49152;

  /// `description.xml` の AVTransport `controlURL`（WiiM Ultra / Pro で確認）。
  static const controlPath = '/upnp/control/rendertransport1';

  static const _service = 'urn:schemas-upnp-org:service:AVTransport:1';

  final Dio _dio;

  WiimConnection? connection;

  /// URL と見出しを渡して鳴らす。
  ///
  /// **`SetAVTransportURI` だけでは鳴らない個体がある**ので、続けて `Play` を
  /// 送る。既に同じ URL が載っていても `Play` は無害。
  Future<void> play(String url, WiimTrackMetadata meta) async {
    await _action(
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
      '<CurrentURI>${escapeXml(url)}</CurrentURI>'
      '<CurrentURIMetaData>${escapeXml(buildDidl(url, meta))}</CurrentURIMetaData>',
    );
    await _action('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  }

  /// **次の 1 曲を本体に預ける**（issue #8）。
  ///
  /// アプリが前面から外れるとポーリングが止まり、曲の終わりを誰も見ていない。
  /// 「終わったのを見て次を送る」だけだと、別のアプリを開いた瞬間にキューが
  /// そこで止まる。先に渡しておけば、**アプリが眠っていても本体が自力で
  /// 次へ移る。**
  ///
  /// 引数名は `NextURI` / `NextURIMetaData`（`SetAVTransportURI` の
  /// `CurrentURI` と綴りが違う）。実機の `rendertransportSCPD.xml` に合わせた。
  Future<void> setNext(String url, WiimTrackMetadata meta) => _action(
    'SetNextAVTransportURI',
    '<InstanceID>0</InstanceID>'
    '<NextURI>${escapeXml(url)}</NextURI>'
    '<NextURIMetaData>${escapeXml(buildDidl(url, meta))}</NextURIMetaData>',
  );

  /// 預けたものを取り下げる。
  ///
  /// **キューの最後まで来たら必ず呼ぶ。** 空にしないと、前の曲のときに預けた
  /// URL が残っていて、止まるはずのところで 1 曲余計に鳴る。
  Future<void> clearNext() => _action(
    'SetNextAVTransportURI',
    '<InstanceID>0</InstanceID><NextURI></NextURI><NextURIMetaData></NextURIMetaData>',
  );

  /// DIDL-Lite を組む。
  ///
  /// **空の要素は出さない。** 空文字を渡すと WiiM 側は `unknow` を返し、
  /// 画面にもそのまま出る。無いものは要素ごと落とす。
  @visibleForTesting
  static String buildDidl(String url, WiimTrackMetadata meta) {
    final buffer = StringBuffer()
      ..write(
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'
        ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
        ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">',
      )
      ..write('<item id="0" parentID="-1" restricted="1">')
      ..write('<upnp:class>object.item.audioItem.musicTrack</upnp:class>')
      ..write('<dc:title>${escapeXml(meta.title)}</dc:title>');
    final artist = _trimmed(meta.artist);
    if (artist != null) {
      // **`dc:creator` と `upnp:artist` の両方を出す。** どちらを読むかは
      // 機種で違い、WiiM は両方あるときだけ確実にアーティストを出す。
      buffer
        ..write('<dc:creator>${escapeXml(artist)}</dc:creator>')
        ..write('<upnp:artist>${escapeXml(artist)}</upnp:artist>');
    }
    final album = _trimmed(meta.album);
    if (album != null) {
      buffer.write('<upnp:album>${escapeXml(album)}</upnp:album>');
    }
    final art = _trimmed(meta.artUrl);
    if (art != null) {
      buffer.write('<upnp:albumArtURI>${escapeXml(art)}</upnp:albumArtURI>');
    }
    final protocol = 'http-get:*:${meta.mimeType ?? 'audio/flac'}:*';
    final duration = meta.duration;
    final durationAttr = duration == null || duration <= Duration.zero
        ? ''
        : ' duration="${_hms(duration)}"';
    buffer
      ..write(
        '<res protocolInfo="${escapeXml(protocol)}"$durationAttr>'
        '${escapeXml(url)}</res>',
      )
      ..write('</item></DIDL-Lite>');
    return buffer.toString();
  }

  /// `HH:MM:SS`。UPnP の時刻表記。
  ///
  /// **ゼロ埋めする。** WiiM 自身が `GetMediaInfo` で `00:04:29` を返すので、
  /// 実機で通ることが分かっているこの形に揃える。
  static String _hms(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String? _trimmed(String? raw) {
    final text = raw?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// **DIDL は SOAP の中に文字列として入るので、2 重にエスケープされる。**
  /// 署名付き URL の `&` は最終的に `&amp;amp;` になる——ここを手で組むと
  /// 必ず間違えるので、組み立ては必ずこの関数を通す。
  @visibleForTesting
  static String escapeXml(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> _action(String name, String args) async {
    final connection = this.connection;
    if (connection == null) throw WiimUpnpException('WiiM の IP が未設定です');
    final envelope =
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$name xmlns:u="$_service">$args</u:$name></s:Body>'
        '</s:Envelope>';
    try {
      await _dio.postUri<String>(
        Uri.parse('http://${connection.host}:$port$controlPath'),
        data: envelope,
        options: Options(
          headers: {
            Headers.contentTypeHeader: 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$_service#$name"',
          },
        ),
      );
    } on DioException catch (e) {
      debugPrint('WiimUpnp $name failed: ${e.type} ${e.response?.statusCode}');
      throw WiimUpnpException('WiiM の UPnP が $name を受け付けませんでした');
    }
  }

  void close() => _dio.close(force: true);
}

/// UPnP 側だけの失敗。**HTTP API の失敗とは分ける**——こちらは
/// `setPlayerCmd:play` に落として鳴らせるので、画面に出す異常ではない。
class WiimUpnpException implements Exception {
  WiimUpnpException(this.message);

  final String message;

  @override
  String toString() => 'WiimUpnpException: $message';
}
