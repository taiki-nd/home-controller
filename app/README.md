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

ブラウザで動かすなら:

```sh
make app-web                        # Chrome で http://localhost:5850
make app-web WEB_HOSTNAME=0.0.0.0   # 同じ LAN の iPad などからも開ける
make app-web-build                  # app/build/web に出す
```

ただし **web ではサインインできない**。`flutter_appauth` に web 実装が無く
（android / ios / macos のみ）、redirect も `app.home-ctl://` のカスタムスキーム
なので、ログインボタンを押すと `MissingPluginException` になる。web で見られる
のはログイン画面まで。再生画面を触りたいときは下の `app-mock` を使う。

## デザインを見る（Spotify につながない）

実機も Client ID も要らない。偽の再生状態を積んだ `lib/main_mock.dart` を
Chrome で開くので、レイアウトの当たりを見るだけならこれが速い。

```sh
make app-mock              # ウィンドウ幅で phone / tablet が切り替わる
make app-mock DEVICE=ipad  # iPad の論理サイズ + セーフエリアの枠で開く (iphone も可)
```

画面上部の細いバーで枠を切り替えられる。再生/停止・曲送り・キュー追加・検索・
デバイス切り替えはモック側の状態を書き換えるので、触った結果もそのまま出る。
アートワークは `web/mock/*.png`（同一オリジンなので背景色の抽出まで動く）。

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
