import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/state/qobuz_controller.dart';

import 'qobuz_support.dart';

/// バックグラウンドでも次の曲へ進む（issue #8）。
///
/// **曲の終わりを見て次を送る方式には、見ている人が要る。** 前面から外れると
/// ポーリングが止まるので、別のアプリを開いた瞬間にキューがそこで止まっていた。
/// `SetNextAVTransportURI` で次の 1 曲を本体に預けておけば、アプリが眠っていても
/// 本体が自力で次へ移る。ここで固定するのは「いつ預けるか」「いつ取り下げるか」
/// 「前面に戻ったときどう辻褄を合わせるか」の 3 つ。
void main() {
  /// ポーリング 1 周ぶん待つ（再生中は 1 秒間隔）。
  Future<void> pollOnce() =>
      Future<void>.delayed(const Duration(milliseconds: 1300));

  test('鳴らし始めた時点で次の 1 曲を本体に預ける', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    await pumpEventQueue();

    // **終わり際まで待たない。** 前面から外れるのが曲の途中とは限らない。
    expect(wiim.preloadedUrls.single, contains('/file/2.flac'));
    // 本体のディスプレイのため、見出しも一緒に渡す（§5.5 と同じ組み立て）。
    expect(wiim.preloadedMeta.single.title, '曲 2');
    expect(wiim.preloadedMeta.single.artist, 'アーティスト');
  });

  test('キューの最後まで来たら預けたものを取り下げる', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await pumpEventQueue();
    await controller.skipNext();
    await pumpEventQueue();

    // **消さないと 1 曲余計に鳴る。** 止まるはずのところで、前の曲のときに
    // 預けた URL がそのまま流れてしまう。
    expect(wiim.commands, contains('clearNext'));
    expect(wiim.preloadedUrls.last, isEmpty);
  });

  test('リピート all なら最後の曲の次に先頭を預ける', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    controller.cycleRepeat(); // off → all
    await pumpEventQueue();
    await controller.skipNext();
    await pumpEventQueue();

    expect(wiim.preloadedUrls.last, contains('/file/1.flac'));
  });

  test('「次に」割り込みが入ったら預け直す', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2)]);
    await pumpEventQueue();
    expect(wiim.preloadedUrls.last, contains('/file/2.flac'));

    await controller.enqueueTrack(track(9), option: QobuzQueueOption.next);
    await pumpEventQueue();

    // 割り込んだ曲が「次」になったのだから、預けてあるものも入れ替える。
    expect(wiim.preloadedUrls.last, contains('/file/9.flac'));
  });

  test('並べ替えても預けたものが古いままにならない', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    await pumpEventQueue();
    // 「これから」の中で 3 を先頭に持ってくる。
    controller.moveItem(1, 0);
    await pumpEventQueue();

    expect(controller.upNext.map((e) => e.track.id), [3, 2]);
    expect(wiim.preloadedUrls.last, contains('/file/3.flac'));
  });

  test('バックグラウンドで本体が進んだぶんを、前面に戻ったときに拾う', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    await pumpEventQueue();
    expect(controller.currentTrack?.id, 1);

    // 別のアプリを開いた。ポーリングは止まる。
    controller.setForeground(false);
    // その間に 1 曲目が終わり、本体は預けてあった 2 曲目へ自力で移った。
    // 曲名は DIDL で渡した `dc:title` がそのまま返る。
    wiim.current = playingStatus(title: '曲 2');

    controller.setForeground(true);
    await pumpEventQueue();
    await pollOnce();

    // **送り直さない。** もう鳴っているので、送れば頭から鳴り直してしまう。
    expect(controller.currentTrack?.id, 2);
    expect(wiim.playedUrls.length, 1);
    // そして次の 1 曲をまた預ける。ここが繋がらないと 2 曲で止まる。
    expect(wiim.preloadedUrls.last, contains('/file/3.flac'));
  });

  test('預けた曲へ移ったあとに止まっていたら、そこから次へ送る', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    await controller.enqueueTracks([track(1), track(2), track(3)]);
    await pumpEventQueue();

    controller.setForeground(false);
    wiim.current = playingStatus(title: '曲 2');
    controller.setForeground(true);
    await pumpEventQueue();
    // 1 周目で「2 曲目に移った」を拾う。
    await pollOnce();
    // 預けられるのは 1 曲ぶんだけなので、2 曲目の終わりで本体は止まる。
    wiim.current = idleStatus(title: '曲 2');
    await pollOnce();

    expect(controller.currentTrack?.id, 3);
    expect(wiim.playedUrls.last, contains('/file/3.flac'));
  });

  test('手でシークして戻しただけでは、進んだことにしない', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);

    // 同じ曲を 2 回積む。**曲名では区別が付かない**ので、位置の動きで見る。
    await controller.enqueueTracks([track(1), track(1)]);
    await pumpEventQueue();
    wiim.current = playingStatus(
      position: const Duration(seconds: 90),
      title: '曲 1',
    );
    await pollOnce();
    // 曲の真ん中から頭へ戻す。終端まで行っていないので曲送りではない。
    wiim.current = playingStatus(
      position: const Duration(seconds: 2),
      title: '曲 1',
    );
    await pollOnce();

    expect(controller.currentIndex, 0);
  });

  test('UPnP が通らない個体では預けず、今までどおり前面で送る', () async {
    final (controller, _, wiim) = await started();
    addTearDown(controller.dispose);
    wiim.upnpAvailable = false;

    await controller.enqueueTracks([track(1), track(2)]);
    await pumpEventQueue();

    // 預ける口が無いだけで、鳴ることは鳴る。**画面に異常は出さない。**
    expect(wiim.preloadedUrls, isEmpty);
    expect(wiim.playedUrls.single, contains('/file/1.flac'));
    expect(controller.errorBanner, isNull);
  });
}
