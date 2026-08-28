import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/qobuz_models.dart';
import 'package:spotify_remote/state/playback_surface.dart';
import 'package:spotify_remote/state/qobuz_controller.dart';

import 'qobuz_support.dart';

/// キューは**このアプリが持つ**（`docs/qobuz-wiim-integration.md` §5.3）。
/// WiiM 側に「キューに追加」が無いぶん、次に再生・末尾に追加・並べ替え・
/// 曲送りの正しさはここでしか担保できない。
void main() {
  group('再生画面から見た口（PlaybackSurface）', () {
    // **music と同じ部品（ProgressRow / TransportControls）を使う前提。**
    // ここが崩れると、Qobuz 側だけ操作が効かない・時間が出ない、という
    // 画面を見ないと分からない壊れ方をする。
    test('QobuzController は PlaybackSurface として渡せる', () async {
      final (controller, _, _) = await started();
      addTearDown(controller.dispose);

      expect(controller, isA<PlaybackSurface>());
    });

    test('繋がっていても、鳴らすものが無ければ押させない', () async {
      final (controller, _, _) = await started();
      addTearDown(controller.dispose);

      expect(controller.status, QobuzStatus.connected);
      expect(controller.currentItem, isNull);
      // 送る先が無いので押させない。**接続だけでは足りない。**
      expect(controller.controlsEnabled, isFalse);
      expect(controller.isStopped, isTrue);

      await controller.enqueueTracks([track(1)]);

      expect(controller.controlsEnabled, isTrue);
      expect(controller.isStopped, isFalse);
    });

    test('繋がっていなければ、キューがあっても押させない', () async {
      final (controller, _, wiim) = await started();
      addTearDown(controller.dispose);
      await controller.enqueueTracks([track(1)]);

      wiim.failing = true;
      await controller.retry();

      expect(controller.status, isNot(QobuzStatus.connected));
      expect(controller.controlsEnabled, isFalse);
    });
  });

  test('繋がったら WiiM の名前と状態が入る', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    expect(controller.status, QobuzStatus.connected);
    expect(controller.deviceName, 'リビング');
    expect(controller.volume, 40);
  });

  test('キューに追加すると末尾に積まれ、止まっていれば鳴り出す', () async {
    final (controller, api, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);

    expect(controller.queue.map((e) => e.track.id), [1, 2]);
    expect(controller.currentTrack?.id, 1);
    // **署名付き URL は再生直前に 1 曲ぶんだけ取る。** 2 曲目は取らない。
    expect(api.fileUrlCalls, [1]);
    expect(wiim.playedUrls.single, contains('/file/1.flac'));
  });

  test('WiiM 本体に渡す絵は small のまま（アプリ内だけ large を使う）', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([
      track(
        1,
        imageUrl: 'https://img/1_230.jpg',
        largeImageUrl: 'https://img/1_600.jpg',
      ),
    ]);

    // **本体の表示は触らない。** 大きい絵を掴ませて崩れるのを避けるため、
    // 機器に出す URL は small で据え置く。
    expect(wiim.playedMeta.single?.artUrl, 'https://img/1_230.jpg');
    expect(controller.currentTrack?.displayImageUrl, 'https://img/1_600.jpg');
  });

  test('UPnP に落ちたら 1 度だけ知らせる（本体の画面が既定に戻る合図）', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);
    wiim.upnpAvailable = false;

    await controller.enqueueTracks([track(1), track(2)]);

    expect(controller.toast, contains('UPnP'));

    // 2 曲目でも同じことを言わない。**曲送りのたびに出すとうるさい。**
    controller.dismissToast();
    await controller.skipNext();
    await pumpEventQueue();
    expect(controller.toast, isNull);
  });

  test('「次に再生」は鳴っている曲の直後に割り込む', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    await controller.enqueueTrack(track(9), option: QobuzQueueOption.next);

    expect(controller.queue.map((e) => e.track.id), [1, 9, 2, 3]);
    expect(controller.upNext.map((e) => e.track.id), [9, 2, 3]);
    expect(controller.toast, contains('次に'));
  });

  test('「再生」はキューを入れ替えて先頭から鳴らす', () async {
    final (controller, api, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await controller.enqueueTrack(track(5), option: QobuzQueueOption.play);

    expect(controller.queue.map((e) => e.track.id), [5]);
    expect(api.fileUrlCalls, [1, 5]);
  });

  test('鳴らせない曲は積まずに、除外した数を知らせる', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([
      track(1),
      track(2, streamable: false),
      track(3),
    ]);

    expect(controller.queue.map((e) => e.track.id), [1, 3]);
    expect(controller.toast, contains('除外'));
  });

  test('トーストは黙って消える', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1)], label: 'パーティ 2026');
    expect(controller.toast, contains('パーティ 2026'));

    // **消し役がいないと画面の下に貼り付いたまま残る。**
    await Future<void>.delayed(const Duration(seconds: 2, milliseconds: 300));

    expect(controller.toast, isNull);
  });

  test('ライブラリから選んだリストはキューを置き換えて鳴り出す', () async {
    final (controller, api, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await controller.playPlaylist(
      const QobuzPlaylist(id: 7, name: 'パーティ 2026', tracksCount: 2),
    );

    // **music の `playPlaylist` と同じ**——積み足しではなく差し替え。
    expect(controller.queue.map((e) => e.track.id), [11, 12]);
    expect(controller.currentTrack?.id, 11);
    expect(api.fileUrlCalls, [1, 11]);
    expect(controller.toast, contains('パーティ 2026 を再生'));
  });

  test('シャッフルを付けて流すと、すでに on でも並びが混ざる', () async {
    final (controller, api, _) = await started();
    addTearDown(controller.dispose);

    api.playlistTracks = [for (var i = 1; i <= 40; i++) track(i)];
    controller.setShuffle(true);

    await controller.playPlaylist(
      const QobuzPlaylist(id: 7, name: 'パーティ 2026', tracksCount: 40),
      shuffle: true,
    );

    expect(controller.shuffleEnabled, isTrue);
    // **1 曲目も混ざる。** 積み直したところなので守る「鳴っている曲」は無い。
    expect(controller.queue.map((e) => e.track.id), isNot([
      for (var i = 1; i <= 40; i++) i,
    ]));
    expect(controller.queue.map((e) => e.track.id).toSet(), {
      for (var i = 1; i <= 40; i++) i,
    });
  });

  test('シャッフル再生を繰り返すと、1 曲目もいろいろ変わる', () async {
    final firsts = <int>{};
    for (var attempt = 0; attempt < 12; attempt++) {
      final (controller, api, _) = await started();
      api.playlistTracks = [for (var i = 1; i <= 40; i++) track(i)];
      await controller.playPlaylist(
        const QobuzPlaylist(id: 7, name: 'パーティ 2026', tracksCount: 40),
        shuffle: true,
      );
      firsts.add(controller.currentTrack!.id);
      controller.dispose();
    }
    // 先頭固定なら {1} だけになる。
    expect(firsts.length, greaterThan(1));
  });

  test('鳴っている曲より前を消しても現在位置がずれない', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    await controller.skipNext();
    expect(controller.currentTrack?.id, 2);

    controller.removeItem(controller.queue.first);

    expect(controller.queue.map((e) => e.track.id), [2, 3]);
    expect(controller.currentTrack?.id, 2);
  });

  test('並べ替えは「これから」の中だけで動く', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3), track(4)]);
    // upNext は [2, 3, 4]。その 3 番目を先頭へ。
    controller.moveItem(2, 0);

    expect(controller.upNext.map((e) => e.track.id), [4, 2, 3]);
    // 鳴っている曲は動かない。
    expect(controller.currentTrack?.id, 1);
  });

  test('曲送りは次の曲の URL をその場で取り直す', () async {
    final (controller, api, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await controller.skipNext();

    expect(controller.currentTrack?.id, 2);
    expect(api.fileUrlCalls, [1, 2]);
    expect(wiim.playedUrls.last, contains('/file/2.flac'));
  });

  test('最後の曲で送っても、リピート off なら止まる（キューは残す）', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1)]);
    await controller.skipNext();

    expect(controller.currentTrack?.id, 1);
    expect(controller.queue, hasLength(1));
  });

  test('リピート all なら最後から先頭へ戻る', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    controller.cycleRepeat(); // off → all
    expect(controller.repeatMode, QobuzRepeatMode.all);

    await controller.skipNext();
    await controller.skipNext();

    expect(controller.currentTrack?.id, 1);
  });

  test('鳴らせなかった曲は飛ばして次へ送る（キューを止めない）', () async {
    final (controller, api, wiim) = await started();
    addTearDown(controller.dispose);

    api.failingTrackIds.add(1);
    await controller.enqueueTracks([track(1), track(2)]);

    expect(controller.currentTrack?.id, 2);
    expect(wiim.playedUrls.single, contains('/file/2.flac'));
    expect(controller.toast, contains('再生できません'));
  });

  test('シャッフルはこれから鳴る分だけを混ぜる', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([for (var i = 1; i <= 12; i++) track(i)]);
    controller.setShuffle(true);

    expect(controller.currentTrack?.id, 1);
    expect(controller.upNext.map((e) => e.track.id).toSet(), {
      for (var i = 2; i <= 12; i++) i,
    });
  });

  test('キューを空にしても鳴っている曲は残す', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    controller.clearQueue();

    expect(controller.queue.map((e) => e.track.id), [1]);
    expect(controller.upNext, isEmpty);
  });

  test('曲の途中で「前の曲」を押したら頭出しになる', () async {
    final (controller, api, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await controller.skipNext();
    wiim.current = playingStatus(position: const Duration(seconds: 30));
    // 再生位置は WiiM を引き直して初めて分かる。操作直後の 1 回
    // （`_refreshSoon`）を待つ。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await controller.skipPrevious();

    expect(controller.currentTrack?.id, 2);
    expect(api.fileUrlCalls, [1, 2, 2]);
  });

  test('曲頭で「前の曲」を押したら 1 つ戻る', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await controller.skipNext();
    await controller.skipPrevious();

    expect(controller.currentTrack?.id, 1);
  });

  test('ログアウトすると設定画面に戻り、キューも消える', () async {
    final (controller, _, _) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1)]);
    await controller.logout();

    expect(controller.status, QobuzStatus.needsSetup);
    expect(controller.needsSetup, isTrue);
    expect(controller.queue, isEmpty);
  });

  test('設定が欠けていれば繋ぎに行かない', () async {
    final controller = QobuzController(
      credentials: FakeQobuzCredentials(account: null),
      wiimCredentials: FakeWiimCredentials(),
      api: FakeQobuzApi(),
      wiim: FakeWiimApi(),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.status, QobuzStatus.needsSetup);
  });
}
