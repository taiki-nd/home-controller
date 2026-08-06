# 自作Spotifyコントローラ 実装メモ / 引き継ぎ

`docs/spotify-custom-controller-design.md`（設計）と Claude Design の
`Spotify Controller.dc.html`（デザイン）をもとに Flutter 実装したときの記録。
**「あとで自分がやらないといけないこと」を先頭にまとめてある。**

- 実装日: 2026-07-30
- アプリ: `app/`（Flutter 3.41.7 / Dart 3.11.5）
- バンドル ID: `app.home-ctl`（App Store Connect の既存レコード `home-ctl` を流用）

---

## 0. まだ残っている作業（これをやらないと動かない）

| # | やること | 場所 | 理由 |
|---|---|---|---|
| 1 | ~~Redirect URI を登録~~ 完了 | Spotify Developer Dashboard → アプリ → Settings → Redirect URIs | **`app.home-ctl://callback/`（末尾スラッシュ必須）**。理由は §3 |
| 2 | **コミットして push** | リポジトリ | まだ 1 コミットも無い（`main` に commit ゼロ）。CI はタグ push で動くので、これが済むまで CI は使えない |
| 3 | GitHub Secrets を 7 個登録 | リポジトリ Settings → Secrets → Actions | CI からの TestFlight 配信に必要（§5） |
| 4 | TestFlight の Internal Testing にテスターを追加 | App Store Connect → home-ctl → TestFlight | Internal は App Review 不要（設計メモ §11） |
| 5 | 設計メモ §10 の実測 | 実機 | 特に「`/me/player/queue` の先読み件数」（§7） |

Client ID は Spotify Developer Dashboard の home-ctl アプリの設定画面で確認する。
secret ではないのでビルドに埋め込んでよい（PKCE なので client secret は存在しない）。
ただし**このリポジトリは public なので値は書かない**。ソースにも置かず
`--dart-define=SPOTIFY_CLIENT_ID=…` で渡す。

---

## 1. TestFlight（配信済み）

**1.0.0 (build 2) をアップロード済み。** Client ID を埋め込み済み。

| build | Delivery UUID | 状態 |
|---|---|---|
| 1 | `887fe263-6ac2-43a7-85f0-f7d1f9dd830a` | `VALID`。ただし後述の `StatusDot` バグ入り。**使わないこと** |
| 2 | `a138d3a6-9ce5-4ca4-b759-94d457b6ad51` | 修正版。**テスターにはこちらを配る** |

> build 1 の不具合: `StatusDot` の `AnimationController` を `late final` の遅延初期化に
> していたため、`pulse: false` のドット（トースト・停止バナー・デバイス一覧）が
> 破棄されるときに dispose() の中で初めて Ticker を作ろうとして落ちる。
> `test/layout_test.dart` を書いたときに検出したので build 2 で修正済み。

配信のためにこのとき作ったもの:

| 種別 | 値 | 備考 |
|---|---|---|
| App Store Connect アプリ | `home-ctl` / `app.home-ctl`（Apple ID `6796252143`） | **既存のものを流用**。新規作成はしていない |
| Bundle ID | `app.home-ctl`（`USZFVG2495`） | 既存 |
| Distribution 証明書 | `Apple Distribution: Taiki Noda`（`YLTRY5T92D`） | 既存。ローカルキーチェーンの秘密鍵と serial 一致を確認済み |
| **プロビジョニングプロファイル** | `home-ctl App Store`（`3Q7GGMV82U` / UUID `4b33582a-…`） | **今回 API で新規作成**。`auth/home-ctl_AppStore.mobileprovision` に保存 |

`auth/` は `.gitignore` 済み（`auth/*`）。プロファイルと .p8 はコミットされない。

### 設計メモからの変更点: バンドル ID

設計メモ §13 は redirect URI を `dev.nadai.spotifyremote://callback` としていたが、
**App Store Connect に `app.home-ctl` のアプリレコードが既にあった**ため、
アプリを新規作成せずそちらに寄せた。バンドル ID / URL スキーム / redirect URI を
すべて `app.home-ctl` で統一している。

- iOS: `ios/Runner/Info.plist` の `CFBundleURLSchemes`
- Android: `android/app/build.gradle.kts` の `manifestPlaceholders["appAuthRedirectScheme"]`
- Dart: `lib/services/spotify_config.dart` の `redirectUri`

3 か所は必ず同じ値にすること。

> Android の `applicationId` だけは `dev.nadai.spotify_remote` のまま。
> Android のパッケージ名にハイフンが使えないため `app.home-ctl` にできない。
> URL スキームとは無関係なので実害はない。

---

## 2. できあがったもの

```
app/lib/
  main.dart                        起動・認証状態でルーティング
  theme/tokens.dart                デザインの色/書体/角丸/ブレークポイント
  models/spotify_models.dart       API レスポンス → Dart（パース時の防御もここ）
  services/
    spotify_config.dart            Client ID・redirect URI・スコープ
    auth_service.dart              PKCE ログイン + トークン保管/更新
    spotify_api.dart               Web API クライアント（401/404/429 の扱い）
  state/player_controller.dart     ポーリング・全 UI 状態・配色抽出
  ui/
    login_screen.dart
    controller_screen.dart         外枠・背景・オーバーレイの合成
    tablet_layout.dart             iPad 横（左アート + 右レール 452px）
    phone_layout.dart              スマホ（ボトムシート 116px / 78%）
    widgets/{atoms,transport,panels,overlays,playlist_button}.dart
```

`flutter analyze` クリーン、`flutter test` 21 件パス。

テストは 3 本:

- `spotify_models_test.dart` — パースの防御（キュー重複畳み込み・204・画像選択・ページング）
- `layout_test.dart` — iPad 1194x834 / iPhone 390x844 の実寸で両レイアウトを描画し、
  例外とオーバーフローが出ないことを確認。**これで build 1 のバグを検出した**
- `widget_test.dart` — ログイン画面とトグルの smoke test

### デザインとの対応

| デザイン | 実装 |
|---|---|
| iPad landscape / iPhone のトグル | `LayoutBuilder` + 幅 900px のブレークポイント（`kTabletBreakpoint`） |
| Sign in 画面 | `login_screen.dart` |
| Playing / Stopped(204) / Device lost | プロトタイプはボタン切替だったが、実装では API の実状態から導出 |
| 右レール 3 タブ / ボトムシート 3 タブ | `RailTabs` + `RailTab` enum |
| Up next / Add tracks / Playlists | `panels.dart` |
| デバイスポップオーバー | `DevicePopover` |
| 停止バナー・No device・2 種の確認・トースト | `overlays.dart` |
| `pulseDot` / `riseIn` アニメーション | `StatusDot` / `TweenAnimationBuilder` |
| Zen Kaku Gothic New / Space Grotesk | `app/assets/fonts/` に同梱 |

### デザインから意図的に変えたところ

**1. 「1716 kbps \| 16bit \| 44.1kHz」のピルをやめた**

Spotify Web API はビットレート・ビット深度・サンプルレートを一切返さない。
固定値を出すと嘘になる（実際 Spotify Connect の WiiM 再生は Ogg Vorbis 320kbps 上限）。
同じ位置・同じ見た目のピルに、**取得できる本物の情報**を入れた:

- `SPOTIFY CONNECT` の帰属表示 — 設計メモ §12 でロゴ/帰属表示が必須なので、これで要件も満たす
- `/me/player/devices` の `volume_percent`

**2. プレイリスト再生に確認ダイアログを追加**

デザインには確認があるが、シャッフルの確定を base 切り替えの**前**に置いた。
逆順だと 1 曲目の選ばれ方が変わってしまうため。

**3. シャッフルトグルを Playlists タブと確認ダイアログの両方に置いた**

デザインどおり。`PUT /me/player/shuffle` で書き、`GET /me/player` の
`shuffle_state` で読む（設計メモ §3）。

**4. サインアウト導線**

デザインに無かったので、帰属表示ピルの長押しに隠した。パーティ中に誤爆させないため。

**5. 再生中の曲のプレイリスト出し入れ（デザインに無い追加）**

now playing に 1 つだけボタンを置いた（iPhone は曲名の右の丸、iPad は
`NOW PLAYING` 行の右のピル）。**行は増やしていない。**

- 入っている → 確認ダイアログを経て `DELETE /playlists/{id}/tracks`
- 入っていない → Playlists タブが「追加先を選ぶ」モードに変わり、選んだ行へ
  `POST /playlists/{id}/tracks`

**「入っているか」は context（再生元）だけで判定している。** Spotify に
「この曲を含むプレイリスト」を返す API は無く、全リストの中身を舐めると数十
リクエストになる。0 リクエストで確実に言えるのは再生元だけなので、そこに限った。
だから「＋」は *どこにも入っていない* ではなく *入れる先を選ぶ* の意味で、
削除側はラベルに必ずリスト名を出して「そのリストから外す」と言い切っている。

`/me/playlists` は他人のプレイリスト（フォロー中）も返すので、追加先の候補は
`GET /me` の `id` と突き合わせて自分のもの（+ コラボ）だけに絞る。id が取れなかった
ときは絞らず、Spotify に 403 を返させる。

**scope を 2 つ増やしている**（`playlist-modify-public` / `playlist-modify-private`）。
既存ユーザーは再連携するまでこの機能だけが 403 になるので、`ReauthBanner`
（新譜のときと同じ導線）で案内する。

---

## 3. 実装上の要点（設計メモとの対応）

- **ステートレス**（§1）: ローカルキューを持たない。`PlayerController` が持つのは
  「直近に取ってきた写し」と UI の一時状態のみ
- **ポーリング**（§8）: 再生中 1s / 一時停止 5s / バックグラウンド停止。
  キューは曲が変わったとき + 操作直後だけ。進捗は `progress_ms` からローカル内挿し、
  進捗バーだけ別 `Listenable`（`progressTick`）で 500ms 更新して全体再ビルドを避けている
- **204 は停止中**（§5）: エラー扱いしない。アンバーのバナーを出すだけで復帰処理は持たない
- **404 は NO_ACTIVE_DEVICE**（§9）: 「公式アプリで一度起こしてください」のオーバーレイ
- **デバイス名が識別子で返ってくる**: Connect スピーカー（WiiM 等）は LAN 上の
  zeroconf で公式クライアントに見つけてもらい、公式クライアントがバックエンドに
  登録して初めて表示名が付く。それより前は `/me/player/devices` の `name` が
  識別子そのものになり、ピルに英数字の羅列が出る。Web API 側にこれを先回りする
  手段は無い（sonir のように OS へ問い合わせる相手がいない）ので、
  `SpotifyDevice.looksLikeIdentifier` で弾いて `Unknown device` に落とし、
  一度でも本名が返ってきたら `DeviceNameCache` に `id → 名前` を残して次から当てる。
  公式アプリで一度選べば、以後は再起動しても名前が出る
- **429**: `Retry-After` を読んで全リクエストをその秒数止め、ポーリング間隔もそれに従う
- **キューの重複パディング**（§4）: 連続する同一 URI を畳む（`QueueSnapshot.fromJson`）。
  テスト済み
- **refresh_token ローテーション**（§13 の罠）: 返ってきた refresh_token を毎回上書き保存。
  リフレッシュ失敗時はサインアウトして再ログインに倒す
- **redirect URI の末尾スラッシュ**: `app.home-ctl://callback/` にすること。Spotify は
  コールバックを `app.home-ctl://callback/?code=…` の形で返すが、AppAuth の
  `OIDAuthorizationSession.shouldHandleURL:` は scheme / host / port / **path** まで
  厳密比較する。登録側を `…//callback`（path=`""`）にすると `"/"` と一致せず URL が
  黙って捨てられ、**`authorizeAndExchangeCode` が永久に返らない**（ブラウザ側は
  コールバックを検知して閉じるので「認証は通ったのに無限ローディング」に見える）。
  Dashboard 側の Redirect URIs も同じ文字列で登録する
- **flutter_appauth は 12.0.0 以上が必須**: このアプリは UIScene を採用している
  （`ios/Runner/Info.plist` の `UIApplicationSceneManifest` と `SceneDelegate.swift`）。
  UIScene 採用アプリではコールバック URL が `scene:openURLContexts:` に配送され、
  `application:openURL:options:` は呼ばれない。11 以前は後者しか実装していないため
  OS 経由で戻るケースを取りこぼす
- **検索**: limit 10 固定・offset ページング。350ms デバウンス + 世代カウンタで
  古いレスポンスを捨てる
- **配色抽出**（§12）: `palette_generator` でアートワークから 2 色抜いて背景グラデーションのみに使用。
  アートワーク自体には何も重ねない

---

## 4. ローカルでの動かし方

```sh
make app-run SPOTIFY_CLIENT_ID=<SPOTIFY_CLIENT_ID>
make app-analyze
make app-test
```

Client ID を渡さないとログイン画面が「SETUP REQUIRED」の案内に変わる（失敗しない）。

---

## 5. CI からの TestFlight 配信

`.github/workflows/ios-testflight.yml`。sonir の同名ワークフローを踏襲。
`ios-v*` / `ios-test-v*` タグ push か手動実行で発火する。

```sh
make ios-test-tag-1.0.1   # 反復用
make ios-tag-1.0.1        # 本番候補
```

### 必要な GitHub Secrets

| Secret | 値 / 作り方 |
|---|---|
| `APPSTORE_API_KEY_ID` | `AD8M84C72U` |
| `APPSTORE_API_ISSUER_ID` | `<ASC_ISSUER_ID>` |
| `APPSTORE_API_KEY_P8_BASE64` | `base64 -i auth/AuthKey_AD8M84C72U.p8 \| pbcopy` |
| `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -i auth/home-ctl_AppStore.mobileprovision \| pbcopy` |
| `IOS_DIST_CERT_P12_BASE64` | キーチェーンアクセスで `Apple Distribution: Taiki Noda` を秘密鍵ごと .p12 書き出し → `base64 -i dist.p12 \| pbcopy` |
| `IOS_DIST_CERT_PASSWORD` | 上記 .p12 に付けたパスワード |
| `SPOTIFY_CLIENT_ID` | `<SPOTIFY_CLIENT_ID>` |

**証明書の .p12 書き出しだけは手作業。** 秘密鍵はキーチェーンから API では取れない。

### 署名方式について（sonir の教訓をそのまま採用）

- 手動署名。`CODE_SIGN_STYLE=Manual` は **Runner ターゲットの Release config にだけ**書く
  （`project.pbxproj`）。xcodebuild のコマンドライン引数で渡すと Pods 全ターゲットに適用され、
  `<pod> does not support provisioning profiles` で Archive が落ちる
- プロファイル名は Runner だけが読む独自変数 `PROFILE_NAME` で渡す
- 自動署名（`-allowProvisioningUpdates`）は使わない。run のたびに証明書を作ろうとして
  Distribution 証明書の上限 2 枚に当たる
- API キーは署名に使わず、altool のアップロード認証だけに使う

### ローカルからの手動配信

CI が使えないときのフォールバック。プロファイルを
`~/Library/MobileDevice/Provisioning Profiles/` に置いた状態で:

```sh
make ios-ship SPOTIFY_CLIENT_ID=<SPOTIFY_CLIENT_ID> \
              ASC_ISSUER_ID=<ASC_ISSUER_ID> \
              BUILD_NUMBER=2
```

`BUILD_NUMBER` は毎回上げること。同じ番号は Apple に弾かれる。

---

## 6. アプリアイコン

「home.ctl」ワードマーク。ピリオドだけ `AppColors.green`（`#1ED760`）にして差し色にする。
sonir の `tools/icon-gen/icon.mjs` を手本にした同型のツールで、SVG を組んで PNG に焼く。

```sh
make icons-install            # 初回のみ (@resvg/resvg-js)
make icons-preview            # 案を 1024px で tools/icon-gen/preview/ に出力
make icons-build              # 確定案を app/ の iOS・Android へ展開 (既定 word-dark)
make icons-adaptive-preview   # Android の円マスクに収まっているか確認
make icons-play               # Play ストア掲載用 512x512
```

| 案 | 中身 | 用途 |
|---|---|---|
| `word-dark` | 1 行の `home.ctl` | **確定案。** 展開済み |
| `stack-dark` | 2 段（`home` / `.ctl`） | 小サイズ重視に振るときの代案 |
| `mono-h` | `h.` モノグラム | ランチャー 48px 最優先にするときの保険 |

決めごと:

- **書体はアプリと同じ Space Grotesk。** ただし同梱物は wght 可変フォントで、resvg は
  可変軸を動かさない（既定インスタンス = Light 300 で描かれる）。`fonts/make-font.py` で
  wght=700 の静的インスタンスを作り、Basic Latin に subset して `tools/icon-gen/fonts/` に
  置いてある（OFL 1.1。`fonts/OFL.txt` 同梱）。フォントをファイル指定で読ませることで
  マシン非依存の決定論ビルドになる
- **サイズは bbox 実測で自動フィット。** 案ごとに font-size を手で詰めない。
  `Resvg#getBBox()` でグリフ外形を測り、`fit`（キャンバス比）に合わせて拡縮 + 光学中心合わせ
- **iOS は alpha 不可。** App Store の要件なので、`pngjs` で RGBA → RGB に再エンコードしている
- **Android は adaptive icon も生成する。** レガシーの正方形 `ic_launcher.png` だけだと
  丸/squircle マスクのランチャーが「白い台紙に載せて縮小」する。前景は中央 66dp の
  安全領域に収まるよう 0.7 倍。themed icon 用のモノクロ層も出している
- 生成物のうち `preview/` と `out/` は再生成できるので `.gitignore` 済み。
  アイコン本体（`app/ios/…/AppIcon.appiconset/`・`app/android/…/mipmap-*/`）はコミットする

---

## 7. Android

**未着手。** 設計メモ §11 には内部テスト配信とあるが、今回は iOS/TestFlight のみ。
コードは Android でもそのままビルドできる状態（`INTERNET` 権限・`appAuthRedirectScheme`・
`minSdk 23` は設定済み）。CI を足すには署名キーストアと Play Console のサービスアカウントが要る。

---

## 8. 未検証（設計メモ §10 の宿題）

実機と WiiM が要るので、実装だけでは潰せなかった項目。

1. **`GET /me/player/queue` の先読み件数を シャッフル ON / OFF 両方で実測する**
   — 最優先。OFF で 2 曲しか返らないなら「Up next」タブの価値がほぼ無くなる。
   重複パディングを畳む処理は入れてあるが、そもそもの件数は実測しないと分からない
2. ~~カスタムスキームが PKCE で通るか~~ **検証済み: 通る。** Universal Links への
   移行は不要だった。ただし末尾スラッシュ必須（§3）。iPad mini (iOS 26.5.2) で確認
3. アイドル中の WiiM が `/me/player/devices` に出るか
4. `POST /me/player/queue` が WiiM 再生中に正しく反映されるか
5. 停止から `/me/player` が 204 を返すまで / デバイス一覧から消えるまでの猶予時間
   — 「停止中」と「デバイス消失」の出し分けの妥当性確認

2 は解決済みなので、残りは WiiM を鳴らしながらの実測。
