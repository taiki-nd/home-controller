import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/spotify_models.dart';

Map<String, dynamic> trackJson({
  required String id,
  String name = 'Track',
  List<String> artists = const ['Artist'],
  int durationMs = 200000,
  List<Map<String, dynamic>>? images,
}) {
  return {
    'id': id,
    'uri': 'spotify:track:$id',
    'name': name,
    'duration_ms': durationMs,
    'artists': [
      for (final artist in artists) {'name': artist},
    ],
    'album': {
      'name': 'Album',
      'images':
          images ??
          const [
            {'url': 'https://img/large.jpg', 'width': 640, 'height': 640},
            {'url': 'https://img/small.jpg', 'width': 64, 'height': 64},
          ],
    },
  };
}

void main() {
  group('Track', () {
    test('複数アーティストを連結する', () {
      final track = Track.fromJson(
        trackJson(id: 'a', artists: ['Daft Punk', 'Pharrell']),
      );
      expect(track!.artists, 'Daft Punk, Pharrell');
    });

    test('uri が無い要素は捨てる', () {
      expect(Track.fromJson({'name': 'no uri'}), isNull);
    });

    test('大きい画像と一覧用の小さい画像を別々に選ぶ', () {
      final track = Track.fromJson(
        trackJson(
          id: 'a',
          images: const [
            {'url': 'https://img/640.jpg', 'width': 640},
            {'url': 'https://img/300.jpg', 'width': 300},
            {'url': 'https://img/64.jpg', 'width': 64},
          ],
        ),
      );
      expect(track!.artworkUrl, 'https://img/640.jpg');
      expect(track.smallArtworkUrl, 'https://img/300.jpg');
    });

    test('要求サイズ以上の画像が無ければ一番大きいものを使う', () {
      final track = Track.fromJson(
        trackJson(
          id: 'a',
          images: const [
            {'url': 'https://img/64.jpg', 'width': 64},
          ],
        ),
      );
      expect(track!.artworkUrl, 'https://img/64.jpg');
    });
  });

  group('QueueSnapshot', () {
    test('連続する同一 URI を畳む（/me/player/queue の重複パディング対策）', () {
      final snapshot = QueueSnapshot.fromJson({
        'queue': [
          trackJson(id: 'a'),
          trackJson(id: 'a'),
          trackJson(id: 'a'),
          trackJson(id: 'b'),
        ],
      });
      expect(snapshot.upcoming.map((t) => t.id).toList(), ['a', 'b']);
    });

    test('離れた位置の重複は残す（本当に 2 回流れる可能性がある）', () {
      final snapshot = QueueSnapshot.fromJson({
        'queue': [trackJson(id: 'a'), trackJson(id: 'b'), trackJson(id: 'a')],
      });
      expect(snapshot.upcoming.map((t) => t.id).toList(), ['a', 'b', 'a']);
    });

    test('queue キーが無くても落ちない', () {
      expect(QueueSnapshot.fromJson(const {}).upcoming, isEmpty);
    });
  });

  group('PlaybackState', () {
    test('停止中は hasContent が false', () {
      expect(PlaybackState.stopped.hasContent, isFalse);
      expect(PlaybackState.stopped.isPlaying, isFalse);
    });

    test('shuffle_state と context を読む', () {
      final state = PlaybackState.fromJson({
        'is_playing': true,
        'progress_ms': 42000,
        'shuffle_state': true,
        'item': trackJson(id: 'a'),
        'device': {'id': 'dev', 'name': 'WiiM Ultra', 'type': 'Speaker'},
        'context': {'uri': 'spotify:playlist:xyz'},
      });
      expect(state.isPlaying, isTrue);
      expect(state.progressMs, 42000);
      expect(state.shuffleState, isTrue);
      expect(state.contextUri, 'spotify:playlist:xyz');
      expect(state.device!.kind, SpotifyDeviceKind.speaker);
      expect(state.hasContent, isTrue);
    });

    test('広告再生中など item が null でも落ちない', () {
      final state = PlaybackState.fromJson({'is_playing': true, 'item': null});
      expect(state.track, isNull);
    });
  });

  group('SearchPage', () {
    test('limit いっぱい返って total に余りがあれば hasMore', () {
      final page = SearchPage.fromJson({
        'tracks': {
          'items': [for (var i = 0; i < 10; i++) trackJson(id: '$i')],
          'offset': 0,
          'limit': 10,
          'total': 47,
        },
      });
      expect(page.tracks, hasLength(10));
      expect(page.hasMore, isTrue);
      expect(page.offset, 0);
    });

    test('最終ページでは hasMore が false', () {
      final page = SearchPage.fromJson({
        'tracks': {
          'items': [for (var i = 0; i < 7; i++) trackJson(id: '$i')],
          'offset': 40,
          'limit': 10,
          'total': 47,
        },
      });
      expect(page.hasMore, isFalse);
    });
  });

  group('PlaylistSummary', () {
    test('desc 行を組み立てる', () {
      final playlist = PlaylistSummary.fromJson({
        'id': 'p1',
        'uri': 'spotify:playlist:p1',
        'name': 'Party 2026',
        'owner': {'display_name': 'nodataiki'},
        'tracks': {'total': 42},
        'images': [
          {'url': 'https://img/pl.jpg', 'width': 300},
        ],
      });
      expect(playlist!.subtitle, 'nodataiki · 42 songs');
      expect(playlist.artworkUrl, 'https://img/pl.jpg');
    });

    test('null 要素を弾く', () {
      expect(PlaylistSummary.fromJson(null), isNull);
    });

    // 2026 年 2 月の移行で `tracks` → `items`。古い鍵しか見ていないと
    // 曲数が全部 0 曲になる（＝移行漏れの目印）。
    test('曲数は items.total から読む（tracks.total も読めるまま）', () {
      final migrated = PlaylistSummary.fromJson({
        'id': 'p1',
        'uri': 'spotify:playlist:p1',
        'name': 'fav_0_pops_rock',
        'owner': {'display_name': 'nadai', 'id': 'nadai'},
        'items': {'total': 12},
      });
      expect(migrated!.trackCount, 12);
      expect(migrated.ownerId, 'nadai');

      final legacy = PlaylistSummary.fromJson({
        'uri': 'spotify:playlist:p2',
        'tracks': {'total': 7},
      });
      expect(legacy!.trackCount, 7);
    });
  });

  group('SpotifyDevice', () {
    test('type から種別を分類する', () {
      SpotifyDeviceKind kindOf(String type) =>
          SpotifyDevice.fromJson({'name': 'x', 'type': type})!.kind;
      expect(kindOf('Speaker'), SpotifyDeviceKind.speaker);
      expect(kindOf('AVR'), SpotifyDeviceKind.speaker);
      expect(kindOf('TV'), SpotifyDeviceKind.tv);
      expect(kindOf('Smartphone'), SpotifyDeviceKind.smartphone);
      expect(kindOf('Computer'), SpotifyDeviceKind.computer);
      expect(kindOf('Unknown'), SpotifyDeviceKind.other);
    });

    test('name が識別子の羅列なら名前として採らない', () {
      // Connect スピーカーが公式クライアントに登録される前の返り。
      final raw = SpotifyDevice.fromJson({
        'id': '0123456789abcdef0123456789abcdef01234567',
        'name': '0123456789abcdef0123456789abcdef01234567',
        'type': 'Speaker',
      })!;
      expect(raw.realName, isNull);
      expect(raw.name, 'Unknown device');

      // 16進 24 文字以上なら id と一致していなくても弾く。
      expect(
        SpotifyDevice.fromJson({
          'name': 'deadbeefdeadbeefdeadbeefdead',
          'type': 'Speaker',
        })!.realName,
        isNull,
      );
    });

    test('人が付けた名前は弾かない', () {
      String? nameOf(String value) =>
          SpotifyDevice.fromJson({'name': value, 'type': 'Speaker'})!.realName;
      expect(nameOf('WiiM Ultra'), 'WiiM Ultra');
      expect(nameOf('DEADBEEF'), 'DEADBEEF'); // 16 進でも 24 文字未満
      expect(nameOf('nodataikinoMacBookPro'), 'nodataikinoMacBookPro');
      expect(nameOf('  WiiM Ultra  '), 'WiiM Ultra');
      expect(nameOf(''), isNull);
    });

    test('withName で名前だけ差し替わる', () {
      final device = SpotifyDevice.fromJson({
        'id': 'dev',
        'name': null,
        'type': 'Speaker',
        'volume_percent': 40,
      })!.withName('WiiM Ultra');
      expect(device.name, 'WiiM Ultra');
      expect(device.id, 'dev');
      expect(device.kind, SpotifyDeviceKind.speaker);
      expect(device.volumePercent, 40);
    });
  });
}
