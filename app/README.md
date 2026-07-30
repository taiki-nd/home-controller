# spotify_remote

自作 Spotify コントローラ。WiiM で鳴らし、iPad を回してみんなで次の曲を入れていく。

- 設計: [`../docs/spotify-custom-controller-design.md`](../docs/spotify-custom-controller-design.md)
- 実装・配信の引き継ぎ: [`../docs/spotify-controller-implementation.md`](../docs/spotify-controller-implementation.md)

## 動かす

Client ID は secret ではないが、ソースには置かず dart-define で渡す。

```sh
make app-run SPOTIFY_CLIENT_ID=xxxxxxxx   # リポジトリルートから
```

渡さない場合はログイン画面が設定手順の案内に変わる（クラッシュはしない）。

## 構成

```
lib/
  main.dart                    起動・認証状態でルーティング
  theme/tokens.dart            デザインの色 / 書体 / 角丸 / ブレークポイント
  models/spotify_models.dart   API レスポンスのパース
  services/                    設定・PKCE 認証・Web API クライアント
  state/player_controller.dart ポーリングと全 UI 状態
  ui/                          ログイン / iPad 横 / スマホ + 共通ウィジェット
```

アプリはステートレス。キューも再生位置も Spotify 側が持ち、ここは
「表示するビューア + コマンド送信機」に徹する。詳細は設計メモ §1。
