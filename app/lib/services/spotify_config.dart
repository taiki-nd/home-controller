/// ビルド時に差し込む設定。
///
/// Client ID は secret ではないのでアプリに埋め込んで構わない（設計メモ §13）。
/// ただしリポジトリに直書きしたくないので dart-define で渡す。
///
///   flutter run --dart-define=SPOTIFY_CLIENT_ID=xxxxxxxx
///
/// **client secret は絶対に埋め込まない。** PKCE なので必要ない。
library;

class SpotifyConfig {
  SpotifyConfig._();

  static const clientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');

  /// カスタムスキーム。**Spotify Developer Dashboard の Redirect URIs に
  /// 一字一句同じ文字列を登録しておく必要がある。**
  ///
  /// 値は iOS のバンドル ID（App Store Connect の既存レコード `app.home-ctl`）に
  /// 揃えてある。iOS は Info.plist の CFBundleURLSchemes、Android は
  /// build.gradle.kts の appAuthRedirectScheme が同じ値であること。
  ///
  /// これが弾かれる（INVALID_CLIENT: Insecure redirect URI）場合は
  /// Universal Links / App Links に切り替える（設計メモ §13 案 2）。
  ///
  /// **末尾のスラッシュは必須。消してはいけない。**
  /// Spotify は `app.home-ctl://callback/?code=…` の形でコールバックを返す。
  /// 一方 AppAuth の `shouldHandleURL:` は path まで厳密比較するため、
  /// ここを `…//callback`（path=""）にすると `"/"` と一致せず URL が黙って
  /// 捨てられ、authorizeAndExchangeCode が永久に返ってこなくなる。
  static const redirectUri = 'app.home-ctl://callback/';

  static const authorizationEndpoint = 'https://accounts.spotify.com/authorize';
  static const tokenEndpoint = 'https://accounts.spotify.com/api/token';
  static const apiBaseUrl = 'https://api.spotify.com/v1';

  static const scopes = <String>[
    'user-read-playback-state',
    'user-modify-playback-state',
    'playlist-read-private',
    'playlist-read-collaborative',
  ];

  static bool get isConfigured => clientId.isNotEmpty;
}
