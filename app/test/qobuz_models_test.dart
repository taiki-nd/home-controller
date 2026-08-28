import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/qobuz_models.dart';

/// 画像の取り分けだけを見る。**2 枚持つのは寸法が桁で違うから**——一覧の
/// サムネは 40〜62px、再生画面は 600px 近くまで伸びる。同じ 1 枚を使うと
/// どちらかが必ず割を食う（`docs/qobuz-wiim-integration.md` §4）。
void main() {
  Map<String, dynamic> trackJson(Map<String, dynamic>? image) => {
    'id': 1,
    'title': '曲',
    'album': {'title': 'アルバム', 'image': ?image},
  };

  test('large があれば再生画面は large、一覧と WiiM は small のまま', () {
    final track = QobuzTrack.tryFrom(
      trackJson({
        'thumbnail': 'https://img/1_50.jpg',
        'small': 'https://img/1_230.jpg',
        'large': 'https://img/1_600.jpg',
      }),
    );

    expect(track!.imageUrl, 'https://img/1_230.jpg');
    expect(track.displayImageUrl, 'https://img/1_600.jpg');
  });

  test('large が無ければ small に落ちる（thumbnail は引き伸ばさない）', () {
    final track = QobuzTrack.tryFrom(
      trackJson({
        'thumbnail': 'https://img/1_50.jpg',
        'small': 'https://img/1_230.jpg',
      }),
    );

    expect(track!.largeImageUrl, isNull);
    expect(track.displayImageUrl, 'https://img/1_230.jpg');
  });

  test('image がまるごと無くても落ちない', () {
    final track = QobuzTrack.tryFrom(trackJson(null));

    expect(track!.displayImageUrl, isNull);
  });

  test('copyWith で large を落とさない', () {
    final track = QobuzTrack.tryFrom(
      trackJson({
        'small': 'https://img/1_230.jpg',
        'large': 'https://img/1_600.jpg',
      }),
    )!.copyWith(playlistTrackId: 7);

    expect(track.playlistTrackId, 7);
    expect(track.displayImageUrl, 'https://img/1_600.jpg');
  });
}
