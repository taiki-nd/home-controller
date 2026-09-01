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

  group('プレイリストのサムネ', _playlistImages);
}

/// プレイリストのサムネ。**`image` は来ない**ので、URL の配列を大きいほう
/// から拾う。自分で作ったプレイリストには `image_rectangle` が付かない
/// （キーが無いか空配列）ので、そこで諦めると一覧が全部のっぺらぼうになる。
void _playlistImages() {
  Map<String, dynamic> playlistJson(Map<String, dynamic> images) => {
    'id': 10,
    'name': 'お気に入り',
    ...images,
  };

  test('編集部のプレイリストは横長の image_rectangle を使う', () {
    final playlist = QobuzPlaylist.tryFrom(
      playlistJson({
        'image_rectangle': ['https://img/rect.jpg'],
        'images300': ['https://img/300.jpg'],
      }),
    );

    expect(playlist!.imageUrl, 'https://img/rect.jpg');
  });

  test('image_rectangle が空でも images300 まで落ちる', () {
    final playlist = QobuzPlaylist.tryFrom(
      playlistJson({
        'image_rectangle': const [],
        'images300': ['https://img/300.jpg'],
        'images150': ['https://img/150.jpg'],
        'images': ['https://img/50.jpg'],
      }),
    );

    expect(playlist!.imageUrl, 'https://img/300.jpg');
  });

  test('自分のプレイリスト（rectangle 無し）でもサムネが出る', () {
    final playlist = QobuzPlaylist.tryFrom(
      playlistJson({
        'images': ['https://img/50.jpg', 'https://img/50b.jpg'],
      }),
    );

    expect(playlist!.imageUrl, 'https://img/50.jpg');
  });

  test('配列が空文字だけなら次のキーへ進む', () {
    final playlist = QobuzPlaylist.tryFrom(
      playlistJson({
        'images300': const [''],
        'images150': ['https://img/150.jpg'],
      }),
    );

    expect(playlist!.imageUrl, 'https://img/150.jpg');
  });

  test('画像がまるごと無くても落ちない', () {
    expect(QobuzPlaylist.tryFrom(playlistJson(const {}))!.imageUrl, isNull);
  });
}
