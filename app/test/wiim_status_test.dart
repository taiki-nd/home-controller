import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_remote/models/wiim_models.dart';

/// `getPlayerStatus` の読み方（`docs/qobuz-wiim-integration.md` §4）。
///
/// **値は全部文字列で返り、曲名は 16 進で返る。** どちらも素直に読むと
/// 全部 null か文字化けになるので、ここで固定の応答から検証する。
void main() {
  test('数値が文字列で返っても読める', () {
    final status = WiimStatus.fromJson(const {
      'status': 'play',
      'curpos': '65000',
      'totlen': '240000',
      'vol': '52',
      'mute': '0',
    });

    expect(status.state, WiimState.play);
    expect(status.isPlaying, isTrue);
    expect(status.position, const Duration(seconds: 65));
    expect(status.duration, const Duration(minutes: 4));
    expect(status.volume, 52);
    expect(status.muted, isFalse);
  });

  test('曲名の 16 進エンコードを解く', () {
    // "Hello" / "ドビュッシー"（UTF-8 → 16 進）
    expect(WiimStatus.decodeHex('48656c6c6f'), 'Hello');
    expect(
      WiimStatus.decodeHex('e38389e38393e383a5e38383e382b7e383bc'),
      'ドビュッシー',
    );
  });

  test('16 進でない文字列はそのまま使う', () {
    expect(WiimStatus.decodeHex('Debussy'), 'Debussy');
    // 桁数が奇数なら 16 進ではありえない。
    expect(WiimStatus.decodeHex('abc'), 'abc');
  });

  test('メタデータ無しの目印は落とす', () {
    expect(WiimStatus.decodeHex('un_known'), isNull);
    expect(WiimStatus.decodeHex(''), isNull);
    expect(WiimStatus.decodeHex(null), isNull);
  });

  test('再生中はポーリングの間を時計で埋める', () {
    final at = DateTime(2026, 8, 28, 12, 0, 0);
    final status = WiimStatus(
      state: WiimState.play,
      position: const Duration(seconds: 10),
      duration: const Duration(minutes: 4),
      volume: 40,
      muted: false,
      receivedAt: at,
    );

    expect(
      status.correctedPosition(at.add(const Duration(milliseconds: 700))),
      const Duration(milliseconds: 10700),
    );
    // 停止中は進めない。
    expect(
      WiimStatus(
        state: WiimState.pause,
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 4),
        volume: 40,
        muted: false,
        receivedAt: at,
      ).correctedPosition(at.add(const Duration(seconds: 5))),
      const Duration(seconds: 10),
    );
  });

  test('曲の長さを超えて進めない', () {
    final at = DateTime(2026, 8, 28, 12, 0, 0);
    final status = WiimStatus(
      state: WiimState.play,
      position: const Duration(seconds: 118),
      duration: const Duration(seconds: 120),
      volume: 40,
      muted: false,
      receivedAt: at,
    );

    expect(
      status.correctedPosition(at.add(const Duration(seconds: 30))),
      const Duration(seconds: 120),
    );
  });
}
