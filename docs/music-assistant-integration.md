# Music Assistant 連携 / Qobuz を WiiM で鳴らす

> **この経路は 2026-08-28 に廃止した。** hi-res は MA を介さず Qobuz を直に
> 叩く形へ一本化し、`app/lib` の MA 実装（`ma_*.dart` 一式）は削除済み。
> 現行の設計は `qobuz-wiim-integration.md`。このメモは MA 側の手順
> （§7）と Qobuz Connect の事情（§8）を残すために置いてある。

Spotify に続く 2 本目の音源として Music Assistant（以下 MA）を足す。狙いは
**Qobuz の HiRes を WiiM にロスレスのまま流すこと**、そして Spotify と Qobuz を
同じ画面のキューで扱えるようにすること。

- 作成日: 2026-08-12
- 対象アプリ: `app/`（Flutter / iOS・iPad）
- 前提: home（HA）と music（Spotify）が既に同居している（`home-assistant-integration.md` §10）

---

## 0. これからやること

| # | やること | 場所 | 済 |
|---|---|---|---|
| 1 | HA に Music Assistant アドオンを入れる（§7） | HA | |
| 2 | MA に Qobuz プロバイダを足す（§7） | MA | |
| 3 | MA に WiiM プロバイダを足す（§7） | MA | |
| 4 | MA で長期トークンを発行する（§7） | MA | |
| 5 | ~~接続情報の保管（§3）~~ | `app/lib/services/ma_credentials.dart` | ✅ |
| 6 | ~~WebSocket セッション（§2）~~ | `app/lib/services/music_assistant_api.dart` | ✅ |
| 7 | ~~モデル（§4）~~ | `app/lib/models/ma_models.dart` | ✅ |
| 8 | ~~状態（§5）~~ | `app/lib/state/ma_controller.dart` | ✅ |
| 9 | ~~画面（§6）~~ | `app/lib/ui/assistant/` | ✅ |
| 10 | 実機の MA に繋いで動作確認（**まだ一度も本物の MA に繋いでいない**） | iPad | |
| 11 | Qobuz のプレイリスト編集（§9 の積み残し） | — | |

---

## 1. なぜ HA 経由ではなく MA を直接叩くのか

MA のプレイヤーは HA に `media_player` エンティティとして出るので、既存の
`HomeController` に相乗りする手もあった。**それでも直結を選んだのは、
`media_player` が MA の持っている情報のほとんどを落とすから。**

| | HA の `media_player` 経由 | MA の WebSocket 直結 |
|---|---|---|
| アプリ側の追加実装 | ほぼ無し（既存の HA クライアントを流用） | セッション + モデル + 状態（本メモ） |
| キューの中身 | **見えない**（次の 1 曲すら出ない） | `player_queues/items` で全件 |
| 検索 | 不可（`media_player.play_media` に URI を渡すだけ） | `music/search` で全プロバイダ横断 |
| プロバイダ（Qobuz / Spotify）の区別 | 出ない | `provider` / `uri` で判る |
| 音質・ストリーム情報 | 出ない | `streamdetails` |
| 更新 | HA の state 変化（属性の丸ごと差し替え） | MA のイベント（`queue_time_updated` は毎秒） |

このアプリは**キューを見せる**のが主目的（`spotify-custom-controller-design.md` §1、
「iPad を回してみんなで次の曲を入れていく」）なので、キューが見えない時点で
`media_player` 経由は要件を満たさない。

接続設定が HA と MA で 2 つになるのは受け入れる。どちらも同じ LAN の
miniPC に載るので、実運用ではホスト名が同じでポートが違うだけになる。

> HA 側にも MA のエンティティは出続けるので、この選択は後から覆せる。
> home 画面のタイルとして音量だけ触る、といった使い方は今までどおりできる。

---

## 2. プロトコル

MA サーバーの WebSocket は `ws://<host>:8095/ws`。**HA とは握手の形が違う。**

```
接続
  ← {"server_id":…, "server_version":…, "schema_version":33, …}   ← 頼まなくても来る
  → {"message_id":"1","command":"auth","args":{"token":"…"}}
  ← {"message_id":"1","result":{"authenticated":true,"user":{…}}}
  → {"message_id":"2","command":"players/all","args":{}}
  ← {"message_id":"2","result":[…]}
  ← {"event":"queue_time_updated","object_id":"<queue_id>","data":12.5}   ← 随時
```

HA との差で、実装に効くところ:

- **`message_id` は文字列**（HA は int）。`result` / `error_code` を持つフレームを
  id で突き合わせるのは同じ。
- **`auth` は schema 28（MA 2.8）以降だけ必須。** それより前のサーバーは
  トークンを持たない。トークン空欄を許して、握手を飛ばせるようにしておく。
- **イベントの購読コマンドが無い。** 認証が通った時点でサーバー側が勝手に
  購読させる（`websocket_client.py: _subscribe_to_events`）。HA の
  `subscribe_events` に当たるものを送ってはいけない。
- **`partial: true` の分割 result がある。** キュー全件のような大きい応答が
  複数フレームで届く。`partial` が付いている間は溜めて、付いていない
  フレームで確定させる。
- **ping はこちらから打たない。** サーバーが `heartbeat=25` で WebSocket の
  ping フレームを撃っており、返らなければサーバー側から閉じる。`HaSession`
  が 30 秒ごとに `ping` コマンドを投げているのは HA が撃たないからで、
  ここで同じことをすると二重になる。
- **エラーは `error_code`（数値）。** 20/21/23 が認証系
  （`AuthenticationRequired` / `AuthenticationFailed` / `InvalidToken`）。
  **これだけは通信断と区別して設定画面へ倒す**（HA の `auth_invalid` と同じ扱い）。
- オンボーディング未完了のサーバーは `message_id: "connection"` で 503 を
  投げて即切る。どのコマンドにも紐づかないので、握手の失敗として拾う。

`HaSession` と骨格は同じなので、WebSocket の口（`HaSocket`）は使い回す。
`ws_socket.dart` に中立な名前で置き直し、`ha_socket.dart` は typedef で
そのまま残した（HA 側のコードとテストは 1 行も変えていない）。

---

## 3. 接続情報

`MaConnection { baseUrl, token }` を Keychain に置く。HA のトークンと同じく
**MA の全権限を持つ本物の secret** なのでビルドには埋めない。

`parseBaseUrl` の既定ポートは **8095**（HA は 8123）。`http` のときだけ補い、
`https` では触らない。リバースプロキシ越しの 443 を書き換えないため——
これは `HaConnection` と同じ判断。

トークンの取り方は §7。

---

## 4. モデル

MA のモデルはサーバー側の dataclass がそのまま JSON になる。全部は要らないので、
画面が使う分だけ削って持つ。

| MA | アプリ | 使いどころ |
|---|---|---|
| `Player` | `MaPlayer` | 出力先の選択・音量。`hide_in_ui` と `available` で絞る |
| `PlayerQueue` | `MaQueue` | 再生状態・シャッフル・リピート・現在位置 |
| `QueueItem` | `MaQueueItem` | キューの行 |
| `Track`/`Album`/`Playlist`/`ItemMapping` | `MaMediaItem` | 検索結果。`uri` があれば投げられる |
| `MediaItemImage` | `MaImage` | §4.1 |

**プレイヤーとキューは 1 対 1 で、`queue_id == player_id`。** それでも別物として
持つ理由は、グループ再生のとき「鳴っているキュー」が親プレイヤー側に移る
（`active_source` / `synced_to`）から。操作は必ずキューに送る。

### 4.1 アートワーク

`MediaItemImage` は生 URL とは限らない。3 通りある。

1. `remotely_accessible: true` → `path` がそのまま URL。
2. `proxy_id` あり（schema 31+）→ `<base>/imageproxy/<proxy_id>?size=N`。
3. どちらも無い → `<base>/imageproxy?path=<二重エンコード>&provider=…&size=N`。

Qobuz は 1 に当たることが多いが、ローカルファイルや一部プロバイダは 2/3 に
なるので 3 通りとも実装する。**`size` は必ず付ける。** WiiM のファームは長い
URL を扱えずアルバムアートを落とすことがあり（MA の Known Issues）、
`imageproxy` の URL は短いに越したことがない。

### 4.2 経過時間

`PlayerQueue.elapsed_time` は `elapsed_time_last_updated`（サーバーの壁時計）
時点の値。**そのまま出すと止まって見える。** 再生中は
`elapsed + (いまの時刻 - last_updated)` で補正する——サーバー側の
`corrected_elapsed_time` と同じ計算。

ただし `queue_time_updated` イベントが毎秒飛んでくるので、Spotify 側
（`PlayerController` の `progressTick`）ほど凝った補間は要らない。イベントが
来たら素直に差し替え、来ない間だけ補正する。

---

## 5. 状態

`MaController extends ChangeNotifier`。立て付けは `HomeController` に揃える。

- **状態は MA が持つ。** イベントを映すだけで、自前のキャッシュを真実にしない。
- 接続は `connecting / connected / offline / authFailed / needsSetup` の 5 状態。
  `authFailed` は再接続しても直らないので backoff を回さず設定画面へ。
- 再接続は 2 秒から倍々で 60 秒頭打ち。バックグラウンドでは張らない。
- 楽観更新は**しない。** MA は操作の結果を数百 ms でイベントとして返すので、
  HA の照明（`state_changed` が来ないことがある）ほど必要がない。二重管理を
  増やさないほうを取る。

扱うイベントは 4 つだけ:

| イベント | すること |
|---|---|
| `player_added` / `player_updated` / `player_removed` | プレイヤー表を更新 |
| `queue_updated` / `queue_added` | キューの状態を差し替え |
| `queue_items_updated` | そのキューの中身を引き直す |
| `queue_time_updated` | 経過秒だけ差し替え（`data` が秒の数値） |

`queue_time_updated` で毎回 `notifyListeners()` すると毎秒フルリビルドになる。
Spotify 側と同じく**進捗だけ別の `ChangeNotifier`（`progressTick`）に流して**、
シークバーだけ描き直す。

---

## 6. 画面

Drawer に 3 つ目のモードとして足す（`AppMode.assistant`、ラベルは `HI-RES`）。

**music（Spotify）と統合しない。** 一つの画面に混ぜると「いまどっちを操作して
いるのか」が見えず、キューも別物なので操作が噛み合わない。壁掛けで人が
入れ替わりながら触る前提だと、**現在地が曖昧なほうが事故る。**

画面の構成は music に寄せる（同じ部屋の同じ iPad で交互に使うので、作法が
違うと戸惑う）:

- 上: 出力先ピル（WiiM の名前 + 状態ドット）→ タップでプレイヤー一覧
- 中: アートワーク + 曲名/アーティスト + シークバー + トランスポート
- 下: キュー / 検索の 2 タブ

既存のウィジェット（`Artwork` / `CapsLabel` / `GlassPill` / `HoverRow` /
`MarqueeText` / `StatusDot`）はそのまま使う。`ProgressRow` と
`TransportControls` は `PlayerController` に直接依存しているので、ここでは
使わず同じ見た目のものを組む——**Spotify 側のシグネチャを MA のために
広げるのは、あとで両方を壊す**ので避けた。

**ラジオ（Radio Mode）のボタンは出さない。** Qobuz プロバイダが未対応
（MA 公式ドキュメントの Known Issues）で、押しても失敗するだけ。

---

## 7. サーバー側の手順（アプリからは触れない）

### 7.1 MA アドオン

HA → 設定 → アドオン → アドオンストア → **Music Assistant**。
「Show in sidebar」を有効にすると HA のサイドバーから MA の UI が開く。

### 7.2 Qobuz

MA の UI → Settings → Music Providers → **ADD PROVIDER** → Qobuz →
Qobuz のユーザー名とパスワードを入力。

- **Qobuz の有料サブスクが必要**（無料プランでは使えない）
- 最大 FLAC 192kHz / 24bit
- Qobuz のお気に入りが MA のライブラリと双方向で同期する
- Radio Mode・レコメンド・歌詞は非対応

### 7.3 WiiM

MA の UI → Settings → Player Providers → **ADD A NEW PROVIDER** → WiiM。
1 分ほどで自動検出される。

- 転送コーデックは既定で **FLAC**（= AirPlay 経由の 44.1/16 ALAC に落ちない）
- 第 1 世代の WiiM は 48kHz/16bit 止まり。プレイヤー設定で上限を確認する
- **HA の WiiM 統合と同じポートを取り合う既知の不具合がある**
  （music-assistant/support#5371）。どちらかに寄せる

### 7.4 トークン

MA の UI → Settings → Users → 自分のユーザー → **Create token**。
表示は一度きり。これをアプリの接続設定に貼る。

MA 2.8 未満のサーバーには認証が無いので、その場合はトークン欄を空のままで
接続できる。

---

## 8. Qobuz Connect について

**MA は Qobuz Connect に対応していない**（要望は music-assistant/discussions#4174）。
WiiM アプリから Qobuz Connect で直接鳴らす経路とは別物で、この連携は
「MA がストリームを取ってきて WiiM に流す」形になる。

音質はどちらもロスレスで届くので、実用上の差は**キューを誰が持つか**だけ。
このアプリの目的（みんなでキューに積む）では MA が持っているほうが都合がよい。

---

## 9. 積み残し

- **プレイリストの編集。** `music/playlists/*` はあるが、Spotify 側で作った
  編集 UI（`panels.dart` の `PlaylistsPanel`）が `SpotifyApi` に直結している。
  共通化してから足す。
- **ライブラリのブラウズ。** `music/browse` でアルバム/アーティストを辿れる。
  検索だけでは足りないと分かってから。
- **グループ再生。** `players/cmd/group` で WiiM をまとめられる。部屋をまたいで
  鳴らしたくなったら。
- **`main_mock.dart` への追加。** 偽 MA を挿してデザインだけ見る口。
