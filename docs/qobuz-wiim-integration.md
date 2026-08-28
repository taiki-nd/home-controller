# Qobuz × WiiM 連携 / Qobuz を直に叩いて WiiM で鳴らす

hi-res モードの設計メモ。**Music Assistant を介さず、iPad から Qobuz と WiiM を
直接叩く。** 公式 Qobuz アプリの UI が好みでないことが動機なので、UI は完全に自前。

- 作成日: 2026-08-28
- 対象アプリ: `app/`（Flutter / iOS・iPad）
- 前提: home（HA）と music（Spotify）が既に同居している
  （`home-assistant-integration.md` §10）
- **`music-assistant-integration.md` を置き換える。** MA 経由の実装は
  この日に削除した（理由は §1）

---

## 0. これからやること

| # | やること | 場所 | 済 |
|---|---|---|---|
| 1 | ~~モデル（§4）~~ | `app/lib/models/qobuz_models.dart` / `wiim_models.dart` | ✅ |
| 2 | ~~署名（§3.3）とテスト~~ | `app/lib/services/qobuz_signature.dart` | ✅ |
| 3 | ~~Qobuz クライアント（§3）~~ | `app/lib/services/qobuz_api.dart` | ✅ |
| 4 | ~~bundle.js からの鍵取り直し（§3.2）~~ | `app/lib/services/qobuz_bundle.dart` | ✅ |
| 5 | ~~WiiM クライアント（§5）~~ | `app/lib/services/wiim_api.dart` | ✅ |
| 6 | ~~キューと状態（§7）~~ | `app/lib/state/qobuz_controller.dart` | ✅ |
| 7 | ~~画面（§8）~~ | `app/lib/ui/hires/` | ✅ |
| 8 | ~~`NSLocalNetworkUsageDescription`（§6）~~ | `app/ios/Runner/Info.plist` | ✅ |
| 9 | **実機で疎通確認**（まだ一度も本物の Qobuz / WiiM に繋いでいない） | iPad | |
| 10 | 署名付き URL の載せ方をどちらかに確定する（§5.2） | 実機 | |
| 11 | プレイリスト編集の UI（API は実装済み、§3.5） | `app/lib/ui/hires/` | |
| 12 | ギャップレス（方式 B）が要るかの判断（§5.3） | 実機 | |
| 13 | ~~LAN から WiiM を探す（§5.1）~~ | `app/lib/services/wiim_discovery.dart` | ✅ |
| 14 | ~~アプリ内ブラウザでの鍵 + ログイン取り込み（§3.2）~~ | `app/lib/services/qobuz_web_login.dart` | ✅ |
| 15 | **実機でブラウザ経路を確かめる**（localStorage のキー名は決め打ちしていないが、Qobuz 側の作りが変われば拾えなくなる） | iPad | |

---

## 1. なぜ MA を捨てたか

MA 経由（HA アドオン + Qobuz プロバイダ + WiiM プロバイダ）でも同じことは
できる。**それでも直叩きに寄せたのは、UI を完全に自前で作るのが目的だから。**
MA を挟むと、キューもプレイリストも MA のモデルに合わせることになり、
「Qobuz のカタログを自分の作法で辿る」という動機に対して層が 1 つ余計になる。

| | MA 経由（削除済み） | Qobuz 直叩き（現行） |
|---|---|---|
| 依存 | HA + MA アドオン（自宅サーバー必須） | 無し。iPad だけで完結 |
| API の安定性 | 公式プロバイダ。壊れたら MA 側が直す | **非公式 app_id / app_secret。いつでも失効する** |
| キューの持ち主 | MA | **このアプリ**（§7） |
| ギャップレス | MA が連続再生 | 曲間にギャップが出る（§5.3） |
| ハイレゾ上限 | MA / WiiM プロバイダ次第 | 24bit/192kHz まで頼める |

**壊れるリスクは Qobuz 側に集中している。** WiiM は公式 API なので問題ない。

### やらないこと

- **Qobuz Connect の制御。** protobuf over WebSocket の非公開プロトコルで、
  専用 app_id（`jwt_qws`）が要る。解析コストが見合わない
- アプリ自身での音声デコード・再生。音を出すのは WiiM だけ
- 楽曲のダウンロード・保存
- **一般配布**（§6）

---

## 2. 構成

```
iPad (Flutter)
 ├─ Qobuz REST v0.2  ──→ 検索 / ブラウズ / プレイリスト管理
 │     └ track/getFileUrl（MD5 署名）→ 署名付き FLAC URL
 └─ WiiM HTTP API    ──→ URL 投入 + トランスポート制御（同一 LAN）
```

サーバーは立てない。iPad から両方を直接叩く。

```
app/lib/
  models/qobuz_models.dart      Qobuz の応答（削って持つ）
  models/wiim_models.dart       getPlayerStatus / getStatusEx
  services/qobuz_signature.dart 署名と MD5（テストあり）
  services/qobuz_api.dart       REST クライアント
  services/qobuz_bundle.dart    bundle.js からの鍵取り直し
  services/qobuz_credentials.dart / wiim_credentials.dart  Keychain
  services/qobuz_web_login.dart アプリ内ブラウザから鍵とトークンを取る（§3.2）
  services/wiim_api.dart        httpapi.asp クライアント
  services/wiim_discovery.dart  LAN から WiiM を探す（§5.1）
  services/insecure_adapter*.dart  自己署名証明書を通す口（web 用の空実装つき）
  services/local_addresses*.dart   自分の IPv4（web 用の空実装つき）
  state/qobuz_controller.dart   キュー・ポーリング・検索・ライブラリ
  ui/hires/                     画面
```

状態管理は既存に合わせて `ChangeNotifier`（Riverpod は入れていない。
home / music が全部これで書かれているので、ここだけ変えても混乱するだけ）。

---

## 3. Qobuz REST API v0.2

### 3.1 前提

**この API は公式にはパートナー限定で、セルフサービスの開発者登録は無い。**
Web プレイヤーが使う `app_id` を流用する。規約の想定外なので個人利用に限定する。

- ベース URL: `https://www.qobuz.com/api.json/0.2`
- 認証ヘッダ: `X-App-Id` / `X-User-Auth-Token`
- 署名が要るのは `track/getFileUrl` だけ

### 3.2 app_id / app_secret

**ビルドに埋めない。** 設定画面で入れるか、`play.qobuz.com` の bundle.js から
取り直す（`QobuzBundle`）。

抽出は正規表現一発では終わらない:

1. `https://play.qobuz.com/login` の HTML から
   `<script src="/resources/<version>/bundle.js">` を拾う
2. `production:{api:{appId:"…",appSecret:"…"}}` から app_id
3. `x.initialSeed("<seed>",window.utimezone.<tz>)` で seed とタイムゾーン
4. `name:"…/<Tz>",info:"<info>",extras:"<extras>"` で残り 2/3
5. `seed + info + extras` を連結 → **末尾 44 文字を落とす** → base64 デコード

**候補は複数出る。どれが当たりかは叩くまで分からない。**
`QobuzController._pickSecret` が検索で拾った 1 曲に対して `track/getFileUrl` を
総当りし、通ったものだけ残す。

#### アプリ内ブラウザから取る（`QobuzWebLogin` / `QobuzWebLoginScreen`）

**素の HTTP で play.qobuz.com を舐める経路は空振りすることがある。**
上の 1.〜5. は Qobuz 側がボット避けを挟むと最初の 1 歩で止まり、しかも
「押しても何も起きない」ようにしか見えない。そこで**本物のブラウザ**で
本人にログインしてもらい、Web プレイヤーが自分で使っている値を横から受け取る
経路を足した。**この画面が鍵（§3.2）とログイン（§3.1）を一度に片付ける。**

- **WebView を Qobuz の外へ出さない。** 既定の WKWebView は iPhone の Safari
  を名乗るので、play.qobuz.com が Universal Link と「アプリで開く」バナーを
  出し、ログインの途中でネイティブアプリに攫われる。対策は 2 つで、
  デスクトップ UA を名乗る（`setUserAgent`）ことと、`onNavigationRequest` で
  `qobuz.com` / `qobuz.net` 以外と非 http(s) スキームを落とすこと。
  **どちらか片方では足りない**
- **締め方は 2 段**（`QobuzWebLogin.allowNavigation`。ここは 2 回壊しているので
  純粋関数にして `qobuz_web_login_test.dart` で両側を固定してある）:
  1. **スキームはフレームを問わず http(s) だけ。** `qobuz://` は
     **副フレームから投げられても OS がアプリを起こす**。「iframe だから安全」
     ではない——ここを開けたまま reCAPTCHA を通そうとして、アプリに攫われる
     状態に戻したことがある
  2. **ホストを見るのは本文だけ。** 副フレームまでホストで締めると reCAPTCHA
     （google.com / gstatic.com の iframe）が読めず、「reCAPTCHA サービスに
     接続できません」でログインそのものができなくなる。許可リストに google を
     並べるのではなく、フレームで見分けること
- **本文の遷移は「通す」のではなく「自分で開き直す」**
  （`QobuzWebLoginScreen._open`）。素直に `navigate` を返すと、iOS が
  「利用者が踏んだリンク」と見なして Universal Link の判定に掛け、qobuz.com が
  Qobuz アプリの関連ドメインに入っているためネイティブアプリに渡してしまう
  （**ログイン直後の遷移でこれが起きる**。スキームを締めても止まらないのは、
  これが `https://` の正規の遷移だから）。プログラムからの `loadRequest` は
  渡らないので、いったん `prevent` して同じ URL を自分で開く。
  自分の `loadRequest` も `onNavigationRequest` に返ってくるので、
  1 件だけ素通しにする目印（`_passthrough`）が要る。
  **本文の POST は捨てることになる**が、Qobuz のログインは XHR で飛ぶ
  （だからトークンを横取りできている）ので、ここを通るのは実質 GET だけ
- **アプリに渡ってしまったら、取り込みは必ず失敗する。** ネイティブアプリの
  ログインは向こうのコンテナに入るだけで、WebView の中は未ログインのまま。
  Web プレイヤーが動かない以上、叩く API も書かれるトークンも無い
- 拾うのは 2 つだけ。**パスワードは見ない**（見る必要がない）
  1. `X-App-Id` / `X-User-Auth-Token` — `fetch` と `XMLHttpRequest` の
     **ヘッダと URL の両方**にフックを掛け、併せて localStorage /
     sessionStorage と `performance` の resource エントリも舐める。
     **キー名は決め打ちしない**（Qobuz 側の都合で変わる）。
     **URL を見るのが要**——Qobuz は `app_id` をヘッダではなく `?app_id=…`
     のクエリで送ることがあり、ヘッダだけ見ているとトークンは取れるのに
     app_id だけ永遠に埋まらない
  2. bundle.js の秘密の素 — **ページ側で読む**。数 MB を JS↔Dart の橋に
     流さないよう、`QobuzBundle.patterns`（Dart と同じ正規表現）に当たった
     箇所だけを送り返し、組み立ては Dart の `QobuzBundle.extract` に一本化する
- フックは遷移で消えるので、`onPageStarted` / `onPageFinished` と 2 秒周期の
  3 か所から**何度でも差し込む**（二重には掛からない）
- トークンには `user_id` が付いてこない。自分のプレイリストの判定に要るので
  `QobuzApi.currentUser()`（`user/get`）で引き直す
- **app_id が揃うのを待たない。** 通信から拾えなくても bundle.js 側に
  `production:{api:{appId:"…"}}` が書いてあるので、そちらで補う
  （`QobuzWebLoginScreen._finish`）。両方揃うまで黙っていると、
  「ログインしたのに画面が何も言わない」という壊れ方をする
- **保存の順は「ログイン → 鍵」。** `applyWebLogin` は先にトークンを確かめて
  保存し、app_secret の総当りはそのあと。逆にすると、候補が 1 本も通らない
  ときに**有効なトークンごと捨てて再ログインを求める**ことになる
  （実際そうなっていた）。鍵が揃わなくても検索とブラウズは署名が要らないので
  動く——止まるのは再生だけ

**`webview_flutter` は web ビルドに実装が無い。** `make app-web` / `app-mock`
では画面が `kIsWeb` を見て「iOS / Android でだけ使えます」に倒れる。

失効の切り分け（`QobuzApi._errorFor`）:

- **401 だけを app_id 切れの目印にしない。** 無効な app_id に 400 が返ることが
  あり、コードだけではトークン切れと区別が付かない。message まで見る
- app_id / signature 系 → `QobuzAppException` →「鍵を取り直す」導線
- token 系 → `QobuzAuthException` →「再ログイン」導線

この 2 つを混ぜると「再ログインを促す → また同じエラー」の無限ループになる。

### 3.3 getFileUrl の署名

```
sig = md5("trackgetFileUrl" + "format_id" + <format_id>
          + "intent" + <intent> + "track_id" + <track_id>
          + <request_ts> + <app_secret>)
```

パラメータ名をアルファベット順に、**区切り文字なしで**キーと値を連結し、
末尾に UNIX 秒と app_secret を付けて MD5。`app_id` / `user_auth_token` /
`request_ts` / `request_sig` は連結に入れない。

`format_id`: `5`=MP3 320 / `6`=FLAC 16-44.1 / `7`=FLAC ≤96kHz / `27`=FLAC >96kHz。
**頼んだ format が返るとは限らない**ので、実際の品質は応答の
`bit_depth` / `sampling_rate` を見る。

**ここが間違うと再生だけが一切できず、原因が分かりにくい。**
`test/qobuz_signature_test.dart` で既知の MD5 と突き合わせている。

### 3.4 URL の失効

返る URL には `etsp`（失効時刻、おおよそ 24 時間）が入っている。
**キュー全曲ぶんを先に取ると後半が死ぬ。再生直前に 1 曲ぶんだけ取る**
（`QobuzController._playCurrent`）。

### 3.5 プレイリスト編集の落とし穴（検証済み）

実機で確かめて確定した挙動。ドキュメントに無いので必ずこの通りに実装する。

1. **`playlist_track_id` と `track_id` は別物。** 削除と並べ替えは前者。
   `playlist/get?extra=tracks` で各アイテムに入る
2. **`addTracks` はカンマ区切りで渡した順序を保つ。**
   → **順序を作りたいなら並べ替え API は要らない**（132 曲を 22 曲ずつ 6 回に
   分けて追加し、移動操作ゼロで全曲正しい位置に入ることを確認済み）
3. **`updateTracksPosition` の `insert_before` は 1 始まりのポジション。**
   目的のインデックス `i` に置くなら `i + 1`。`insert_before=0` は先頭に
   クランプされて 1 と区別が付かない。`QobuzApi.moveTracks` が +1 している
4. **削除の反映に遅延がある。** `deleteTracks` の直後の `playlist/get` は
   削除前を返すことがある。削除結果を前提に位置計算しない
5. **順序を伴う一括操作は「全削除 → 正しい順序で一括再登録」が最も確実。**
   実行前に全 `track_id` を順序付きでバックアップすること
6. **ハイレゾ判定は `hires_streamable`。** 併せて `maximum_bit_depth` /
   `maximum_sampling_rate` を表示に使う（画面では曲名の下のバッジ）
7. **同一楽曲の別バージョン照合は ISRC 完全一致のみ信じる。**
   曲名＋再生時間はクラシックで別演奏を掴む（誤爆を確認済み）

---

## 4. WiiM の応答の読み方

**値はすべて文字列で返る。** `"vol":"52"` の形なので、int で読もうとすると
全部 null になる。

**曲名などのメタデータは 16 進で返ることがある**（`48656c6c6f` → `Hello`）。
ただし素の文字列で返るファームもあるので、16 進として読めないときはそのまま
使う（`WiimStatus.decodeHex`）。`un_known` はメタデータ無しの目印なので落とす。

`totlen` は FLAC のストリームで 0 になることがある。そのときは Qobuz 側の
メタデータで補う（`QobuzController.duration`）。

ポーリングは**再生中 1 秒 / 停止中 5 秒**。1 秒ごとに全画面を作り直さないよう、
シークバーだけ `progressTick` で別に描き直す（Spotify 側と同じ作法）。
ポーリングの間は端末の時計で埋める（`correctedPosition`）。

---

## 5. WiiM に投げる

公式ドキュメント: `https://www.wiimhome.com/pdf/HTTP%20API%20for%20WiiM%20Products.pdf`

- 形式: `https://<device-ip>/httpapi.asp?command=<command>`
- **自己署名証明書なので検証を切る**（`insecure_adapter_io.dart`）。
  **Qobuz 用の Dio とは必ず分ける**——検証を切ってよいのは LAN の WiiM だけ

### 5.1 デバイス発見（`WiimDiscovery`）

**SSDP も mDNS も使わない。** iOS でマルチキャストを使うには
`com.apple.developer.networking.multicast` が要り、Apple の申請と承認が必要。

代わりに **/24 をユニキャストで端から叩く。** 権限は
`NSLocalNetworkUsageDescription` だけで済み、許可を取りこぼしていても
「無言のタイムアウト」ではなく**「0 台」という見える形**で出る。

- 自分の IPv4（`NetworkInterface`）から /24 を割り出す。
  プライベート（10 / 172.16-31 / 192.168）だけ、**最大 2 セグメント**
- `.1`〜`.254` に `getStatusEx` を投げる。同時 24 本、1 台あたり 1.2 秒で打ち切り
- `DeviceName` があり `uuid` / `project` / `firmware` のどれかを持つものだけ
  LinkPlay と見なす
- **見つかっても勝手には繋がない。** 集合住宅では隣家の WiiM が見えるので、
  一覧から人が選ぶ（`QobuzController.selectWiim`）
- 見つかるそばから一覧に出し、進捗（`scanProgress`）も出す。
  **無音で 10 秒待たされると壊れて見える**

**IP 手入力は残してある。** VLAN を切っている・/24 でない・探索が空振り、
のいずれでもここから入れられる（WiiM 側は DHCP 予約で固定しておくと確実）。

`NetworkInterface` は `dart:io` にしか無いので、web ビルドを壊さないよう
`local_addresses.dart` で条件付き import にしている（`insecure_adapter` と同型）。

### 5.2 署名付き URL の載せ方（**未確定**）

`setPlayerCmd:play:<url>` に渡す URL は `?` と `&` を含む。
httpapi.asp のクエリ解析で途中まで切られる個体があるという報告と、
生で通るという報告が両方ある。**片方に賭けていない。**

- 既定は生（`WiimUrlEncoding.raw`）
- 送ってから 3 秒鳴らなければ percent-encode で 1 回だけ送り直す
- 鳴った時点でどちらが通ったかを覚え、以降はそれで送る
  （`QobuzController._onStatus`）

**実機で確定したらこの節を書き換え、片方を消すこと。**
なお `hex_playlist` は「特殊文字で失敗しないように」16 進で渡す口だが、
**m3u / ASX のプレイリスト URL 用**なので単曲には使えない。

### 5.3 キューは誰が持つか

**WiiM の HTTP API に「キューに追加」は無い。** 公式コマンドは
`play:url` と `hex_playlist` だけで、キュー操作（`AppendTracksInQueue` など）は
UPnP の `urn:schemas-wiimu-com:service:PlayQueue:1`（ポート 49152 / SOAP、
`QueueContext` に DIDL メタデータを組む）側にある。

したがって **キューはアプリが持ち、1 曲ずつ URL を投げる**（方式 A）。

- 制御が完全に手の内にある。**次に再生・末尾に追加・並べ替え・削除が
  Qobuz にも WiiM にも触らずに済む**
- 曲の終わり（`status` が `stop` に落ちる）を見て次を投げる
- **曲間にギャップが出る**

方式 B（m3u を生成して `hex_playlist` で渡す）は、ギャップレスになる代わりに
署名付き URL の失効問題が効き、m3u を配る軽量 HTTP サーバー（`shelf`）が要る。
**クラシックで曲間の切れ目が問題になってから**検討する。

UPnP の PlayQueue を使えば WiiM 側にキューを持たせられるが、
**実機なしでは検証できない**（DIDL の組み方が当たっているか確かめようがない）
ので着手していない。方式 B を検討するときに一緒に測る。

### 5.4 曲の終わりの見分け方

`play` を送った直後の WiiM は、URL を掴んでバッファするまで `stop` のまま。
**これを終了と読むと 1 曲目を送った瞬間に次へ飛ぶ。**

- 送ってから 8 秒は終了と見なさない（`_startGrace`）
- 8 秒を過ぎて `stop` になり、**かつ再生位置が進んでいた**なら曲の終わり
- 位置が 0 のまま止まっているなら掴み損ね。次へ送らずエラーを出す

---

## 6. セキュリティと配布

- Qobuz のトークンは `flutter_secure_storage`（Keychain）。**ログ出力厳禁**
- `app_id` / `app_secret` もビルドに埋めず設定として置く（差し替え可能）
- **App Store 配布・OSS 公開はしない。** 非公式の app_id / app_secret に
  依存しているため。`ENABLE_MUSIC=false` の公開ビルドでは
  music（Spotify）ごとコンパイル時に落ちる（`release-strategy.md` §3）
- アプリ内ブラウザ（§3.2）は**パスワードを見ない**。拾うのはログイン後の
  Web プレイヤーが自分で使っている `X-App-Id` / `X-User-Auth-Token` と
  bundle.js の秘密の素だけで、いずれも Keychain に置く。
  `QobuzWebLoginResult.toString()` はトークンを伏せる
- iOS: `NSLocalNetworkUsageDescription` が必須。
  **これが無いと WiiM への接続が無言で失敗する**（ダイアログすら出ない）。
  再生は WiiM 側で行われるので、オーディオのバックグラウンドモードは不要

---

## 7. 状態（`QobuzController`）

- **キューはこのアプリが持つ。** 行ごとに ID を振る（同じ曲を 2 回積めるので、
  行の同一性は曲 ID では決まらない）
- 「次に再生」は現在位置の直後に割り込ませる。「末尾に追加」は追加するだけ
- **鳴らせない曲（`streamable: false`）は積まない。** 積むとそこで止まって
  「なぜか次に進まない」になる
- 1 曲取れなくても次へ送る。**バナーではなくトーストで知らせる**
  （次の曲が鳴り出すとバナーは消えてしまう）
- シャッフルは**これから鳴る分だけ**混ぜる。鳴っている曲は動かさない
- リピートは off → all → one。**アプリ側で回す**（WiiM の `loopmode` は
  デバイスがコントロールポイントのときしか効かない）

---

## 8. 画面（`app/lib/ui/hires/`）

`ma_view` の作法をそのまま引き継いでいる（壁掛けで人が交代しながら触るので、
music と混ぜない）。

- 左（広い時）: アートワーク・曲名・**品質バッジ（HI-RES / bit / kHz）**・
  シークバー・トランスポート
- 右: **Up next / Library / Add tracks** のタブ。文言も並びも music の
  `RailTabs` に合わせる（「Search」ではなく「Add tracks」なのは、ここが
  探す場所ではなく**積む場所**だから）
- キューは**ドラッグで並べ替えられる**（アプリがキューを持っているからできる）
- Library の行を選ぶ＝**そのリストを流す**（`QueuePlayConfirm` で確認 →
  キューを置き換え）。music の Playlists タブと同じ動き。iPad は右端の
  Play、スマホは行全体。中身に潜って 1 曲ずつ積みたいときは「曲を見る」から
- 中身（listing）と検索結果の行には「次に再生」と「キューに追加」を
  **常に 2 つとも出す**。長押しやメニューの奥に隠すと使われない
- トーストは必ず `QobuzController._showToast` を通す。`_toast` に直接
  入れると誰も消さず、**画面の下に文言が貼り付いたまま残る**
- ヘッダのピルはタップで音量。**スライダーは離した時にだけ送る**
  （ドラッグ中に毎フレーム httpapi を叩くと WiiM が詰まる）

設定画面（`qobuz_setup_screen.dart`）の注意:

- **画面自身が `QobuzController` を購読する**（`ListenableBuilder`）。
  Drawer から `Navigator.push` で開くと `QobuzView` の外側に居るため、
  これが無いと `notifyListeners` がどこにも届かない。
  **「Web から取り直す」を押しても進行中もエラーも何も出ない**という
  壊れ方をしていたのがこれ
- **再生画面は music と同じ作法に揃える**（`PlaybackSurface`）。
  Spotify（`PlayerController`）と Qobuz（`QobuzController`）は中身がまるで
  別物だが、「いま何が鳴っていて、送る・止める・シークする」という画面から
  見た形は同じなので、そこだけを抜いた口を両方に実装させ、`ProgressRow` /
  `TransportControls` / `SwipeSkip` / `OrbitingLight` / `ArtworkBackdrop` を
  共有する。**配色の抽出も共通**（`ArtworkPaletteResolver`）——出どころが
  同じでも掛け方が違うと、音源を切り替えたときに別物に見える。
  片方にしか無いもの（Spotify のプレイリスト、Qobuz の音質バッジ・
  シャッフル・リピート）は口に入れず、各画面が自分のコントローラを直に見る
- Drawer の名前は **SPOTIFY / QOBUZ**。「MUSIC / HI-RES」だと何が鳴るのかが
  分からない（HI-RES は音質バッジの語としても使っているので紛らわしい）
- 入口は**アプリ内ブラウザ（§3.2）1 つ**。手入力とメール + パスワードは
  「うまくいかないときは」に畳む。**残しはする**——非公式の経路なので、
  いつ空振りしてもおかしくない
- **「ログイン済みか」と「鍵が揃っているか」を分けて出す**（`_QobuzState`）。
  1 つの見出しに混ぜていたせいで、ログインは取り込めているのに未設定にしか
  見えず、もう一度ログインさせられているように感じる画面になっていた

---

## 9. テスト

- `qobuz_signature_test.dart` — **署名は固定値と突き合わせる**
- `qobuz_bundle_test.dart` — 抽出は純粋関数として切ってあるので入力を固定できる
- `qobuz_web_login_test.dart` — 橋を渡ってきた値の読み方と、
  **削り込んでも（`reduce`）鍵が組み立つこと**。JS 自体は実機でしか動かない
- `wiim_discovery_test.dart` — 舐めるホストの並べ方（純粋関数）と、
  叩く口を差し替えた走査。**ネットワークは触らない**
- `qobuz_setup_test.dart` — 探索 → 選択、ブラウザからの取り込み（§3.2）
- `wiim_status_test.dart` — 文字列の数値・16 進・時計での補間
- `qobuz_controller_test.dart` — キュー（次に再生 / 追加 / 並べ替え / 削除 /
  曲送り / リピート / 鳴らせない曲の扱い）

プレイリスト編集は破壊的なので、**実データで試す前に捨てプレイリストで
検証すること**（§3.5 の 5 を必ず踏まえる）。

---

## 10. 積み残し

- **実機での疎通**（§0 の 9・10）。ここが最大の未検証点
- プレイリスト編集の UI。API（作成・追加・削除・並べ替え）は実装済み
- お気に入りの曲・アーティストからの導線（いまはアルバムだけ）
- 破壊的操作の前の自動バックアップ（JSON をローカル保存）
- `main_mock.dart` への追加。偽 Qobuz を挿してデザインだけ見る口
