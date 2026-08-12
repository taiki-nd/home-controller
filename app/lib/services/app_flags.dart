/// ビルド時に決まるフラグ。
///
/// `docs/release-strategy.md` §3 のとおり、**実行時トグルにはしない。**
/// 公開ビルドに機能を残したまま審査後に有効化する形は App Store ガイドライン
/// 2.3.1（隠し機能）に触れる。コンパイル時に落とせば、公開バイナリからは
/// そのコードパスに到達できない。
class AppFlags {
  AppFlags._();

  /// music（Spotify）と hi-res（Music Assistant）を出すか。
  ///
  /// 2 つを同じフラグで束ねているのは、どちらも音楽サービスの資格情報を
  /// 前提にした内輪向けの機能で、公開ビルドではまとめて落としたいから。
  ///
  /// - `ios-test-v*` タグ / 手元のビルド → true（内輪配布。Spotify の
  ///   development mode は 25 ユーザーまでなのでこの範囲で収まる）
  /// - `ios-v*` タグ → false（App Store 公開用。home 単体になる）
  ///
  /// 既定を true にしているのは `make app-run` を今までどおり動かすため。
  static const enableMusic = bool.fromEnvironment(
    'ENABLE_MUSIC',
    defaultValue: true,
  );
}
