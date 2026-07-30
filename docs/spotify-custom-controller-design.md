# 自作Spotifyコントローラ 設計メモ（簡略版）

Flutter製の自作Spotifyクライアント。WiiMで再生し、iPadを回して次に流す曲を入れていく。

- 作成日: 2026-07-30 / 簡略版に改訂
- 配布形態: TestFlight（内輪）+ Android内部テスト
- 対象: iOS / Android、モバイル + タブレット

---

## 1. 設計方針

**アプリはステートレス。状態はすべてSpotifyが持つ。**

キューの編集・削除、および「今すぐ再生」でキューが飛ぶことを
仕様として受け入れたため、アプリ側でキュー状態を持つ必要がない。
アプリは「Spotifyの状態を表示するビューア」＋「コマンド送信機」に徹する。

### この方針の帰結

- ローカルキュー管理・JIT push・URI突き合わせがすべて不要
- コールドスタート時の状態復元が不要
- 複数端末で同時に開いても状態がズレない
  （将来「各自の端末から曲を入れる」に広げても設計変更が不要）
- ベースプレイリストが自作である必要がない（§4参照）
- ベースプレイリスト自体も任意。キューを使い切った後はSpotifyの標準挙動
  （オートプレイ or 停止）に任せ、アプリは復帰処理を持たない（§5参照）

### App Remote SDKは不要

再生をWiiMに任せるため端末ローカルでの音声出力が発生しない。
Web APIのみで完結し、ネイティブプラグイン依存はゼロ。
iOSのバックグラウンド接続断問題も発生しない。

---

## 2. アーキテクチャ

```
┌──────────────────────────────┐
│  iPad / iPhone / Android     │
│  Flutter（表示 + コマンド送信） │
│  ローカル状態を持たない        │
└──────────┬───────────────────┘
           │ Web API (HTTPS)
           ↓
┌──────────────────────────────┐
│  Spotify クラウド             │
│  [user queue] ← 唯一の状態    │
│  [context]    ← プレイリスト  │
└──────────┬───────────────────┘
           ↓ Spotify Connect
┌──────────────────────────────┐
│  WiiM（実際の再生・音声出力）  │
└──────────────────────────────┘
```

---

## 3. 操作仕様

| 操作 | 実装 |
|---|---|
| ベース再生 | `PUT /me/player/play`（`context_uri` + `device_id`） |
| 次に再生へ追加 | `POST /me/player/queue` — 1コールのみ |
| 今すぐ再生 | `PUT /me/player/play`（`uris:[track]`）※キューとcontextは消える |
| 次の曲 | `POST /me/player/next` |
| 前の曲 | `POST /me/player/previous` |
| 追加のキャンセル | 流れ始めたら `POST /me/player/next` で飛ばす |
| 検索 | `GET /search`（limit最大10、offsetでページング） |
| 再生順の表示 | `GET /me/player/queue` の返り値をそのまま描画 |
| シャッフル切替 | `PUT /me/player/shuffle`（状態は `GET /me/player` の `shuffle_state`） |

### シャッフルは通常のトグルとして出す

旧設計（順番をプレイリストの中身から自前計算する方式）では強制OFFが必要だったが、
`GET /me/player/queue` に一本化した現設計では**その制約は不要**。

- `PUT /me/player/shuffle` で切り替え、現在の状態は `GET /me/player` の
  `shuffle_state` から読んでトグル表示に使う
- **パーティキューはシャッフルの影響を受けない。**
  `POST /me/player/queue` で入れた曲は挿入順（FIFO）で再生され、
  シャッフルはcontext側（プレイリスト本体）の順序だけを乱す。
  手で入れた曲が勝手に並び替わることはないため、要件と衝突しない
- ただし先読み件数がシャッフル状態に依存する可能性がある（§4・§10参照）

---

## 4. 再生順の表示

`GET /me/player/queue` の返り値を素直にリスト表示するだけ。

- context由来の曲もキュー追加分も、実際に流れる順で返ってくる
- 両者を区別する必要がないので、突き合わせロジックが不要
- 先読みは20曲程度が上限
- **ベースプレイリストが自作である必要がない。**
  他人のプレイリストやSpotify編集部のものでも先の順番が出る
  （プレイリストの中身を `GET /playlists/{id}/items` で取る必要がないため、
  2026年2月の「非所有プレイリストは items が返らない」制限を回避できる）

### このエンドポイントの既知の不安定性（要注意）

`/me/player/queue` は長年挙動が不安定なことで知られており、
以下がコミュニティで報告されている（数年前から未修正）。

- **シャッフルONで最大20曲返るのに、OFFでは2曲しか返らないことがある**
- 20曲を超えるキューでも20曲で打ち切られる（limit/offsetパラメータが無い）
- キューが2曲しかないとき、同じ曲を繰り返して20曲ぶんに埋めて返すことがある
- シャッフル/リピート状態によってレスポンスの内容が変わる
- context由来の曲とキュー追加分・Radio由来を区別するフラグが無い

参照: https://community.spotify.com/t5/Spotify-for-Developers/Inconsistent-behaviour-of-me-player-queue-endpoint/m-p/5474162

**もしOFFで2曲しか返らないなら「順番表示」という要件自体が成立しない。**
シャッフルをUIに出すかどうかは、§10の実測結果を見て決める。
重複パディングが起きる場合は、連続する同一URIを畳む処理を入れる。

---

## 5. 「今すぐ再生」とキューの尽き

**採用: `PUT /me/player/play` に `uris:[track_uri]` を渡す。1コールで完結。**

確実にその曲が鳴る。副作用として既存のキューとcontextが消えるが、
どちらも仕様として許容する。

### キューを使い切った後は Spotify の標準挙動に任せる

アプリ側での復帰処理は**行わない**。結果は3通りに分岐するが、いずれも許容する。

| アカウント設定 / 環境 | 挙動 |
|---|---|
| オートプレイON（デフォルト） | アルゴリズムが選んだ曲が流れ続ける |
| オートプレイOFF | 停止する |
| Connectデバイスがオートプレイ非対応 | 停止する |

オートプレイ設定はWeb APIから変更できない（公式アプリの設定のみ）。
アプリはこれに干渉せず、ユーザーの設定をそのまま尊重する。

これにより以下がすべて不要になる:

- 204/停止の検知と `context_uri` の投げ直し
- ベースcontextの必須化（**ベースプレイリストは任意。単曲やキューだけで始めてもよい**）
- キュー残数の先読み
- ポーリング維持のための Wakelock

### 停止した場合のUI要件（唯一の残り作業）

再生が止まってしばらく経つと、WiiMが非アクティブ化して
`GET /me/player` が 204 を返し、最終的に `/me/player/devices` からも消える。
この状態で `PUT /me/player/play` は 404 (NO_ACTIVE_DEVICE) になる。

復帰ロジックは持たないので、代わりに**状態を正しく見せる**。

- 204 を「停止中」として明示的に表示する（エラー扱いにしない）
- デバイスが一覧から消えていたら §9 の導線を出す

### 却下案

`POST queue` → `POST next` の2コール方式はcontextが維持されるが、
キューに既に曲が入っていると**その先頭が鳴ってしまう**。
ユーザーから見て理由の分からない挙動になるため採用しない。

---

## 6. Spotify APIの制約（2026年7月時点）

### 2026年2月の Development Mode 変更

2026-02-06のアナウンス。2/11から新規Client IDに適用、3/9から既存にも適用
（エンドポイント削減のみ既存クライアントへの適用が延期中）。

- **Spotify Premium アカウント必須**（開発者本体のみ。認可するテストユーザー側は不要）
- **開発者ひとりにつき Development Mode Client ID は1個**
- **Client IDあたり認可ユーザーは最大5人**
- 利用可能エンドポイントの削減

参照: https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security

### 本プロジェクトへの影響

**Player系エンドポイントは全て残存。今回の用途は直撃を免れている。**

残る影響:

- **認可ユーザー5人** — 実質的な配布上限。
  パーティでは自分のアカウントで再生し、他人はiPadのUIを触るだけという運用になる
- **`/search` の limit 上限が 50→10、デフォルト 20→5** — ページング前提
- audio-features（BPM・エネルギー等）と popularity は廃止済み。
  「BPM表示」「人気度ソート」等は実装不可
- Extended Quota は実質不可能（法人登録 + MAU 25万）。Development Modeで完結させる
- **Smart Shuffle はWeb APIから読み書きできない。**
  公式アプリ側でONになっていると、プレイリストに入っていない推薦曲が混ざってくる。
  パーティ用途では選曲が意図から外れる可能性があるため、事前に公式アプリで確認する。
  `PUT /me/player/shuffle` で通常シャッフルを操作したとき
  Smart Shuffle 側がどうなるかは未検証

### 認証

- **Authorization Code + PKCE 必須**（Implicit Grantは2025年11月廃止）
- スコープ: `user-read-playback-state` / `user-modify-playback-state` /
  `playlist-read-private` / `playlist-read-collaborative`

---

## 7. エンドポイント一覧

| 用途 | エンドポイント |
|---|---|
| デバイス一覧（WiiM探索） | `GET /me/player/devices` |
| WiiMへ転送 | `PUT /me/player` |
| プレイリスト再生 | `PUT /me/player/play`（`context_uri`） |
| 単曲を今すぐ再生 | `PUT /me/player/play`（`uris`） |
| 次 / 前 | `POST /me/player/next` / `previous` |
| 検索 | `GET /search` |
| キュー投入 | `POST /me/player/queue` |
| 現在のキュー取得 | `GET /me/player/queue` |
| 再生状態監視 | `GET /me/player` |
| シャッフル切替 | `PUT /me/player/shuffle` |
| 音量 | `PUT /me/player/volume` |
| プレイリスト一覧 | `GET /me/playlists` |

参照: https://developer.spotify.com/documentation/web-api/references/changes/february-2026

---

## 8. ポーリング戦略

| 対象 | 間隔・条件 |
|---|---|
| `GET /me/player` | 再生中 & フォアグラウンド: 1秒 / 一時停止中: 5秒 / バックグラウンド: 停止 |
| `GET /me/player/queue` | 曲が変わったとき + キュー操作の直後のみ |

進捗バーは毎回APIを叩かず、取得した `progress_ms` を起点にローカル内挿する。

```dart
final elapsed = DateTime.now().difference(_stateFetchedAt);
final displayPos = _state.isPlaying
    ? _state.progressMs + elapsed
    : _state.progressMs;
```

429が返ったら `Retry-After` ヘッダを尊重してバックオフ。

---

## 9. WiiM固有の注意

- **アイドル状態のWiiMは `/me/player/devices` に出てこないことがある。**
  一度公式Spotifyアプリから再生を投げて起こすと以降は見えるようになる。
  → 「デバイスが見つからない → 公式アプリで一度起こしてください」の導線を用意する
- 音量は `PUT /me/player/volume` で効く。
  DAC直結でゲイン管理をしている場合はUIに露出させないほうが安全

---

## 10. 検証すべき項目（着手前に確認）

1. **WiiMが `/me/player/devices` に安定して出るか**
   （アイドル時、スリープ復帰後の挙動）
2. **`GET /me/player/queue` の先読み件数を、シャッフルON / OFF の両方で実測する**
   - 自作プレイリスト / 非所有プレイリストの両方で
   - キューが1〜2曲のときに重複パディングが起きるか
   - これが少ないと順番表示の価値が下がる。**最優先で確認する項目**
3. `POST /me/player/queue` 投入がWiiM再生中に正しく反映されるか
4. **カスタムスキームのリダイレクトURIがPKCEで通るか**（§13参照）
   通らなければ Universal Links / App Links に切り替える。
   認証が通らないと何も始まらないので、**着手初日に確認する**
5. **再生停止から `/me/player` が204を返すまで、および `/me/player/devices` から
   WiiMが消えるまでの猶予時間**（§5のUI要件の設計に使う。復帰ロジックは不要だが、
   「停止中」と「デバイス消失」を切り分けて表示するために実測しておく）

---

## 11. 配布

### iOS / TestFlight

- Apple Developer Program（年 $99）
- **Internal Testing（App Store Connectユーザー100人まで）はApp Review不要** → これに限定する
- External Testing は Beta App Review が入る。Spotifyブランド絡みは説明を求められる可能性あり
- Spotify側の認可ユーザーが5人上限なので、外部配布する意味がない

### Android

内部テスト配信 または APK直渡し / Firebase App Distribution

---

## 12. Spotifyデザインガイドライン

UIの自作自体は公認。ただし以下の条項がある。

- アートワークの改変・クロップ・上への重ね書きは禁止
- Spotifyロゴとコンテンツの帰属表示が必須
- 他サービスのコンテンツと同一ビューに混在させない

内輪配布なら実務上問題になりにくいが、
**「アートワークから配色を抽出して背景に使う」程度に留めるのが安全。**

参照: https://developer.spotify.com/documentation/design

---

## 13. Flutter実装メモ

### サーバーは不要（Flutterのみで完結する）

サーバーが必要になる典型的な理由がいずれも該当しない。

| サーバーが必要になる理由 | 本プロジェクト |
|---|---|
| client secret を隠す | **PKCEなので secret 自体が不要** |
| CORS回避 | ネイティブアプリなので無関係（Flutter Webなら必要になる） |
| Webhook受信 | Spotifyにpushは無い。ポーリングのみ |
| 複数ユーザーの状態共有 | 状態はSpotifyが持つ（§1のステートレス方針） |
| トークンリフレッシュ | 端末上で完結できる |

書き込み系も全てクライアントから直接叩ける。中間層は一切不要。

### リダイレクトURI（唯一の詰まりどころ）

2025年4月9日以降に作成したアプリは、**リダイレクトURIがHTTPS必須**
（ループバックアドレスのみHTTP可）。カスタムスキームは引き続きサポートされる
とされているが、モバイルではApp Links / Universal Linksが推奨されている。

参照: https://developer.spotify.com/documentation/web-api/concepts/redirect_uri

**注意**: 2025年4月のルール適用直後、PKCEでカスタムスキームを使うと
`INVALID_CLIENT: Insecure redirect URI` が返る報告が複数上がっていた。
その後「修正された」というコメントもあるが確証はない。

上から順に試す。

| 案 | 内容 | 評価 |
|---|---|---|
| 1 | カスタムスキーム `dev.nadai.spotifyremote://callback` | 最も簡単。`flutter_appauth` にそのまま渡す。まずこれを試す |
| 2 | Universal Links / App Links | `nadai.dev` に `apple-app-site-association` と `assetlinks.json` を置くだけ。**静的ファイル2つなのでサーバーではない**（Cloudflare Pagesで足りる）。1が通らなければこちら |
| 3 | ループバック `http://127.0.0.1:PORT` | アプリ内にHTTPサーバーを立てる必要があり、特にiOSで筋が悪い。**使わない** |

### トークン管理の注意

- **PKCEではリフレッシュのたびに新しい `refresh_token` が返る（ローテーション）。**
  返ってきたものを毎回 `flutter_secure_storage` に上書き保存しないと、
  次のリフレッシュで失敗して再ログインになる。踏みやすい罠
- Client ID はアプリに埋め込んで構わない（secretではない）
- **client secret は絶対に埋め込まない。** PKCEなら必要ないので使う場面がない

### パッケージ

| 用途 | パッケージ |
|---|---|
| OAuth (PKCE) | `flutter_appauth` |
| HTTP | `dio` または `http` |
| トークン保存 | `flutter_secure_storage` |
| 配色抽出 | `palette_generator` |

状態管理は、ローカルキューが不要になったため軽量な構成で足りる
（ポーリング結果のStream + `ValueNotifier` 程度）。

Spotify SDK系のネイティブプラグインは**不要**。

### タブレット対応

- `LayoutBuilder` でブレークポイント切り替え
- 横幅が取れるときはアートワーク大判 + 情報を横並び
- キュー一覧は iPad では常時サイドに表示、スマホではボトムシート

---

## 付録: 検討したが採用しなかった選択肢

### App Remote SDK

`spotify_sdk`（brim-borium）でiOS/Android両対応。レイテンシほぼゼロ。

**不採用理由**: WiiM再生が前提でローカル音声出力が不要。
iOSはバックグラウンドで接続を切るのが作法とされており常駐表示ができない。
端末へのSpotifyアプリのインストールも必須になる。

### ローカルキュー + JIT push方式

アプリ側でパーティリストを保持し、Spotifyのuser queueには先頭2曲だけを
逐次投入する方式。キューの削除・並べ替えが可能になる。

**不採用理由**: 削除・並べ替えを仕様から外したため、複雑さに見合わない。
状態の二重管理、コールドスタート時の復元、push済みURIの突き合わせが発生する。

### Android の NotificationListenerService

MediaSessionを直接読めばSpotify API・Premium・Client IDすべて不要。

**不採用理由**: iOSに対応する仕組みがない。
またWiiM再生時は端末側にMediaSessionが立たないため今回の構成では機能しない。

### Spotify Jam（グループセッション）

ゲストが自分のスマホから共有キューに追加できる。iPadを回す必要がない。

**不採用理由**: Web APIが存在せず自作アプリから制御できない。UIもSpotifyのもの。
ただし運用の代替案としては有効。
