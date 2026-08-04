# Matter デバイス連携 / Home Assistant 導入メモ

home-ctl から Matter デバイスを操作するための構成検討と、Home Assistant（以下 HA）
導入の手順。**まだ何も作っていない段階のメモ。**

- 作成日: 2026-08-04
- 対象アプリ: `app/`（Flutter / iOS・iPad）
- 前提: Spotify コントローラと同じアプリに家電操作を同居させる

---

## 0. これからやること

| # | やること | 場所 | 済 |
|---|---|---|---|
| 1 | miniPC を調達（§1） | — | |
| 2 | ルーターの IPv6 を有効化・IoT 機器と同一セグメントに寄せる（§3） | ルーター管理画面 | |
| 3 | HA OS をインストール（§2） | miniPC | |
| 4 | Matter Server アドオンを入れる（§4） | HA | |
| 5 | Thread を使うなら border router を用意（§5） | — | |
| 6 | デバイスを commissioning（§6） | iPhone の HA コンパニオンアプリ | |
| 7 | 長期アクセストークンを発行して secure storage に入れる（§7） | HA プロフィール画面 | |
| 8 | Flutter 側に HA クライアントを実装（§8） | `app/lib/services/` | |
| 9 | 外出先アクセスの方式を決める（§9） | — | |
| 10 | `AppShell`（Drawer + IndexedStack）を作り、既存レイアウトを `ui/music/` に移設（§10） | `app/lib/ui/` | |
| 11 | home 画面とタイルを実装（§10・§11） | `app/lib/ui/home/` | |
| 12 | 無操作 2〜3 分で music に自動復帰を入れる（§10・**焼きつき対策の本命**） | `AppShell` | |

---

## 1. なぜ Home Assistant なのか

Google Home APIs（Nest Hub をハブにする）も技術的には成立するが、
**このアプリの構成だと HA のほうが圧倒的に安い**という判断。

| | Google Home APIs | Home Assistant |
|---|---|---|
| アプリ側の実装 | Swift SDK → **platform channel 必須** | HTTP / WebSocket → **Dart だけで完結** |
| iOS ビルドへの影響 | App Attest 必須（シミュレータ不可）、App Groups、`MatterExtension` の別ターゲット、専用プロファイル | なし |
| 審査・登録 | Google Home Developer Console 登録、OAuth 設定、一般公開なら審査 | なし |
| 常時稼働の機材 | 不要（Nest Hub がハブ） | **必要**（miniPC） |
| 扱えるデバイス | Google がサポートする範囲 | Matter 以外（Hue・赤外線・SwitchBot 等）も同じ API に載る |

`MatterExtension` と App Attest が入ると `makefile` の `ios-*` 一式（手動署名）が
確実に複雑化する。**署名まわりを触らずに済むのが HA を選ぶ最大の理由。**

> Matter デバイスは multi-admin で複数ファブリックに同時参加できる。
> **Google Home に入れたまま HA にも追加できる**ので、この選択は後から覆せる。

参考:
- [Home APIs iOS SDK](https://developers.home.google.com/apis/ios/sdk)
- [Home APIs 概要](https://developers.home.google.com/apis)

---

## 2. ハードウェア: miniPC で問題ない

むしろ推奨。N100 クラスで十分すぎる。

| 項目 | 推奨 | 理由 |
|---|---|---|
| CPU | Intel N100 相当 | HA + Matter Server は非力な x86 で足りる |
| メモリ | 8GB | 4GB でも動くが余裕を持たせる |
| ストレージ | **SSD / NVMe 128GB〜** | **SD カードは避ける。** recorder が常時 DB に書くので寿命で死ぬ。RasPi より miniPC が有利な最大のポイント |
| ネットワーク | **有線 LAN** | Matter は mDNS と IPv6 に強く依存する。Wi-Fi 経由は事故の元 |
| Bluetooth | あると少し楽 | BLE commissioning に使える。ただし §6 の運用なら必須ではない |
| 802.15.4 ラジオ | **載っていない** | Thread を使うなら別途 border router が要る（§5） |

BIOS で **「電源復帰時に自動起動（Restore on AC Power Loss）」を ON** にしておく。
停電のたびに電源ボタンを押しに行かなくて済む。

---

## 3. ネットワークの下ごしらえ（ここが一番詰まる）

**HA を入れる前にやる。** 後からだと切り分けが面倒になる。

- **ルーターで IPv6 を有効化。** Matter / Thread はリンクローカル IPv6 前提
- **HA・スマート家電・iPhone を同じ L2 セグメントに置く。**
  ゲスト SSID や IoT 用 VLAN に分けると mDNS が届かず commissioning が失敗する
- **miniPC に DHCP 固定割り当て。** アプリから叩く先が動くと面倒
- Thread border router を HA と別ホストで動かす場合、**IPv6 の RIO
  （Route Information Option）が正しく流れている必要がある**。
  ここが通っていないと「ペアリングは通るのに数分後に unavailable になる」という
  一番わかりにくい症状が出る

---

## 4. Home Assistant OS のインストール

**Container 版でも Supervised でもなく、HA OS（ベアメタル）を選ぶ。**
Matter Server と OpenThread Border Router は「アドオン」として提供されていて、
**アドオン機構は HA OS（と Supervised）にしか無い**ため。

1. `haos_generic-x86-64-*.img.xz` を DL
2. Ventoy か Balena Etcher で USB に焼く
3. USB から起動して内蔵ストレージに書き込む（x86 版はインストーラが内蔵ディスクへ dd する）
4. 再起動後 `http://homeassistant.local:8123` でオンボーディング

### Matter Server アドオン

設定 → アドオン → アドオンストア → **Matter Server** をインストールして起動。
その後 設定 → デバイスとサービス → 統合を追加 → **Matter**。
アドオンが動いていれば自動検出されるはず。

---

## 5. Thread border router（必要なら）

**Wi-Fi 接続の Matter デバイスしか使わないならこの節は丸ごとスキップしてよい。**

| 方式 | 内容 | 評価 |
|---|---|---|
| **Connect ZBT-1 / ZBT-2** | miniPC に USB 挿し + **OpenThread Border Router アドオン** | **王道。** HA で完結する。2026.6 で OTBR 1.4 が beta を抜け、内蔵 mDNS 処理で接続の安定性が改善 |
| Apple TV 4K / HomePod mini | 既存の Apple 系ハブを TBR として使う | iOS の HA コンパニオンアプリが **Apple の Thread 資格情報を HA に取り込める**ので手軽 |
| Nest Hub 2nd gen / Nest Wifi Pro | 既存の Google 系ハブ | **資格情報が取り出しにくい。期待値は下げておく** |

---

## 6. デバイスの commissioning

**iPhone の HA コンパニオンアプリから追加するのが最短。**
iOS 標準の Matter 追加フローが呼ばれて、BLE + Wi-Fi/Thread の設定を渡してくれる。
miniPC 側に Bluetooth が無くても成立するのはこれが理由。

すでに Google Home / Apple Home に登録済みのデバイスは、各アプリの
**「デバイスを共有」/「Turn On Pairing Mode」から共有コードを発行**して HA に渡す
（multi-admin）。既存の家の設定を壊さずに追加できる。

---

## 7. 認証情報

HA のユーザープロフィール最下部 → **長期アクセストークン**を発行。
**表示は一度きり**なので、その場で保存先に入れること。

Spotify の Client ID と同じ方針で扱う:

- **リポジトリには置かない**（このリポジトリは public）
- ソースにも直書きしない
- 端末側は secure storage（Keychain）、開発時は `--dart-define` で渡す

Client ID と違い**これは本物の secret**（HA の全権限を持つ）なので、
ビルドへの埋め込みはしないこと。アプリの設定画面から入力させて Keychain に保存する。

---

## 8. Flutter からの接続

ネイティブコードは一切不要。パッケージは `web_socket_channel` + `http` で足りる。

### WebSocket（本命）

`ws://<ha>:8123/api/websocket`

1. 接続すると `auth_required` が来る
2. `{"type":"auth","access_token":"…"}` を送る → `auth_ok`
3. `get_states` で初期状態を取得
4. `subscribe_events`（`event_type: state_changed`）で差分を購読

**状態がプッシュで届くのでポーリング不要。** 操作も同じ WS 上で `call_service`
（例: `light.turn_on`）。

### REST（実装初期・フォールバック）

`POST /api/services/<domain>/<service>`、`GET /api/states` で同等のことができる。
まず REST で通してから WS に寄せる進め方でもよい。

### 設計上の注意

- **接続先を `homeassistant.local` 頼みにしない。**
  設定画面で IP を直接指定できるようにしておく。iPad で mDNS が解決できないときに
  詰む（Spotify のときの web 版と同じで、「動かない環境がある」前提で作る）
- 構造としては Spotify と同じ「外部 API クライアント」。
  既存の作りに素直に乗るはず

---

## 9. 外出先からのアクセス

| 方式 | 費用 | 備考 |
|---|---|---|
| **Nabu Casa Cloud** | 月額 | 設定ゼロ。HA 開発の資金源でもある |
| **Tailscale アドオン** | 無料 | iPhone 側にも Tailscale を入れる |

**ポート開放は非推奨。** 長期アクセストークン = 家中の全権限なので、
インターネットに直接晒さないこと。

---

## 10. UI 設計: home / music を完全に分ける

**ハンバーガーメニューで最上位を切り替える。** Home 側は右レール 452px に間借り
するのではなく、画面（1194x834）を丸ごと使う。

### シェルの構成

```
lib/ui/app_shell.dart      ← 新規。Drawer + IndexedStack
lib/ui/music/…             ← 既存の tablet_layout / phone_layout を移設
lib/ui/home/…              ← 新規
```

**`Navigator.push` ではなく `IndexedStack` で、両方のサブツリーを生かしたまま
切り替える。** 作り直すと、music に戻るたびに `PlayerController` が再生成されて
アートワークが一瞬消えてから入り直す。壁掛けだとこのチラつきが目立つ。
HA の WebSocket も再接続 → 全 state 取り直しになるので、購読を落とさないこと。

`PlayerController` / `HomeController` はシェルより上（`main.dart`）で持って、
両モードに渡す。

### Drawer の中身

```
┌─────────────────┐
│  ♪ MUSIC        │  ← 再生中なら曲名を小さく添える
│  ⌂ HOME         │  ← ON の数を添える（「3 つ点灯」）
│  ─────────      │
│  ○ リビング      │  ← 既存のデバイスピル
│  設定            │
└─────────────────┘
```

**2 項目だけにしない。** 完全分離すると music にいる間は家の状態が見えなくなる。
Drawer を開いた瞬間に両方の要約が見えれば、「消し忘れの確認のためだけにモードを
切り替える」が起きない。

### home 側のレイアウト

```
┌──── 280 ────┬────────────────────────────────┐
│ ☰           │  リビング                       │
│             │                                │
│ リビング  ●  │   ┌──────┐ ┌──────┐ ┌──────┐   │
│ 寝室        │   │ 天井  │ │ 間接  │ │エアコン│   │
│ キッチン  ●  │   └──────┘ └──────┘ └──────┘   │
│             │   ┌──────┐ ┌──────┐            │
│ ─────       │   │おやすみ│ │ 換気  │            │
│ シーン       │   └──────┘ └──────┘            │
│             │                                │
│             │  22.4°C   54%                  │
└─────────────┴────────────────────────────────┘
```

music 側の「左に主役・右にレール」と**鏡像**にする。左右の重心が同じだと
分離した感じが出ない。部屋名の横の `●` は「その部屋で何か ON」のインジケータ。

タイルは 3 列固定、1 枚 ≒ 200x140。**壁掛けで指が届く大きさを優先し、詰め込まない。**

### 状態の持ち方

設計メモ §1 の「アプリはステートレス、状態は Spotify が持つ」が、そのまま
**「状態は HA が持つ」**に置き換わる。しかも HA のほうが条件が良く、WebSocket の
`state_changed` がプッシュで来るぶん Spotify のポーリングより正確。

- タップ → 楽観的に UI へ反映 → 数百 ms 後に HA から確定が届く
- 届かなければ元に戻してバナー。**`204 NO CONTENT` / `404 NO_ACTIVE_DEVICE` 用に
  作った amber・danger のバナー語彙をそのまま流用する**（「照明が応答しない」は
  デバイス消失と同じ扱いでよい）

### 色

`tokens.dart` の `green` は Connect / Add to queue 専用だが、**home モードには
Spotify の記号が一切出てこない**ので、home 側に独自のアクセントを 1 色置ける。

ただし **ON = 面が光る（`SoftSurface` の輝度を上げる）は残す。**

| 状態 | 見た目 |
|---|---|
| OFF | 既存の面のまま（暗い） |
| ON | 面が淡く光り、文字が白に上がる |
| 応答なし | 面が沈んで文字が落ちる |

照明が実際に光るというメタファーがそのまま状態表示になるので、凡例が要らない。

### 焼きつき対策（必須）

全画面の固定グリッド + 常時表示の ☰ は、**このアプリで今までで一番焼きつきに
弱い絵**になる。レールに間借りしていたときより条件が悪い。

| 対策 | 内容 |
|---|---|
| **無操作で music に自動復帰** | 2〜3 分。**これが本命。** home は「用があるときだけ開く画面」と割り切る |
| ☰ を単独の常時アイコンにしない | music 側の既存要素（デバイスピルの行）に寄せる |
| タイルに枠線を引かない | `d8cf512` と同じ理由。面と背景の色差だけで区切る |
| 起動時は必ず music | 前回のモードを復元しない。壁掛けの既定状態は Now Playing |

> ハンバーガーは現在地が見えず切り替えに 2 タップかかるのが弱点だが、
> **「無操作で music に自動復帰」を入れると実質的に消える** — 放っておけば
> 必ず music に戻っているため。

### ジェスチャの衝突

`swipe_skip.dart` が Now Playing 面で水平スワイプを取っているので、**Drawer の
エッジスワイプと競合する。** `drawerEnableOpenDragGesture: false` にして
☰ タップ専用にするか、`drawerEdgeDragWidth` を絞る。曲送りのつもりで Drawer が
出るのは壁掛けだとストレスが大きい。

---

## 11. UI 部品とドメインの対応

付録 A のとおりドメインは多いが、**必要なウィジェットは 5 種類に収まる。**

| ウィジェット | 対応ドメイン |
|---|---|
| トグルタイル | `switch` `light`(単機能) `fan` `input_boolean` `automation` |
| 押すだけタイル | `button` `scene` `script` `vacuum`(帰還) |
| スライダ付き詳細シート | `light`(調光・色) `fan` `cover` `media_player`(音量) |
| ステッパ付き詳細シート | `climate` `humidifier` `water_heater` |
| 数値行（押せない） | `sensor` `binary_sensor` `weather` |

**タップ = トグル、長押し = 詳細シート**の 2 段構えにして、グリッドに
スライダを埋め込まない。壁掛け iPad でタイル内スライダを指で操作するのは事故が多い。

センサーは**押せない**ので、タイルの形にすると押せると誤解される。グリッドの下に
`caps()` ラベルの数値行として 1 行に流す（既存の attribution 行と同じ扱い）。

### 実装順

`light` / `switch` / `scene` / `climate` / `sensor` の 5 つで日本の家の実用の
9 割が埋まる。`cover`（カーテン）はその次。

**`media_player` は後回し。** home-ctl 自体が music 側で Spotify を扱っているので、
先に入れると役割が混ざる。

§8 の「HA のラベルで選抜する」と組み合わせると、アプリはドメインを見て
ウィジェットを選ぶだけになるので、対応ドメインを増やすコストはほぼゼロ。

---

## 12. 参考リンク

- [Matter Integration in Home Assistant](https://isupradesign.com/matter-integration-home-assistant-setup-guide/)
- [Python Matter WebSocket Server](https://pypi.org/project/python-matter-server/5.0.1)
- [Best Thread border routers for Home Assistant and Matter in 2026](https://evezone.evetech.co.za/deep-dives/best-thread-border-router-for-home-assistant-and-matter-in-2026)
- [Google Home APIs iOS SDK](https://developers.home.google.com/apis/ios/sdk)（不採用側の資料）

---

## 付録 A. HA で操作できるもの一覧

ドメイン単位。カッコ内が HA のドメイン名で、`call_service` の前半になる。

### 照明・スイッチ系

```
LEDライト (light)
  ON/OFF                turn_on / turn_off / toggle
  調光                  brightness 0–255
  色温度                color_temp_kelvin（2000–6500K 程度、機種による）
  カラー                rgb_color / hs_color / xy_color
  エフェクト             effect（キャンドル・虹など、対応機種のみ）
  フェード時間           transition（秒）
  ※ supported_color_modes を見て、その機種にある機能だけ出す

スイッチ・スマートプラグ (switch)
  ON/OFF                turn_on / turn_off / toggle
  ※ 調光なし。SwitchBot のボット（物理ボタン押し）もここ

ボタン (button)
  押す                  press
  ※ 状態を持たない。押すだけのもの

シーン (scene)
  適用                  turn_on
  ※「おやすみ」「映画」など。複数機器の状態をまとめて再現

スクリプト / オートメーション (script / automation)
  実行                  script.turn_on / automation.trigger
  有効・無効             automation.turn_on / turn_off
```

### 空調・水まわり

```
エアコン (climate)
  ON/OFF                hvac_mode: off
  運転モード             hvac_mode: heat / cool / heat_cool / auto / dry / fan_only
  温度設定               set_temperature（暖房・冷房で別々に持てる機種もある）
  風量                   set_fan_mode（auto / low / medium / high …）
  風向                   set_swing_mode
  プリセット              set_preset_mode（eco / boost / away / sleep …）
  現在温度                current_temperature（読み取り専用）
  ※ 赤外線リモコン経由（Nature Remo / SwitchBot Hub）でもこのドメインに載る

扇風機・サーキュレーター・換気扇 (fan)
  ON/OFF                turn_on / turn_off
  風量                   set_percentage（0–100）
  プリセット              set_preset_mode
  首振り                 oscillate
  回転方向                set_direction（正転・逆転）

加湿器・除湿機 (humidifier)
  ON/OFF                turn_on / turn_off
  目標湿度                set_humidity
  モード                  set_mode

給湯器・エコキュート (water_heater)
  ON/OFF                turn_on / turn_off
  温度設定                set_temperature
  運転モード               set_operation_mode
  外出モード               set_away_mode

バルブ・水栓 (valve)
  開閉                   open_valve / close_valve
  開度                   set_valve_position
```

### 開閉・施錠

```
カーテン・ブラインド・シャッター・ガレージ (cover)
  開ける / 閉じる         open_cover / close_cover
  停止                   stop_cover
  位置指定                set_cover_position（0–100%）
  羽根の角度              set_cover_tilt_position（ブラインドのみ）

スマートロック (lock)
  施錠 / 解錠            lock / unlock
  ラッチを開ける           open（対応機種のみ、玄関を実際に開ける）
  暗証番号                code（要求する設定にもできる）

警報 (alarm_control_panel)
  在宅警戒                alarm_arm_home
  外出警戒                alarm_arm_away
  就寝警戒                alarm_arm_night
  解除                   alarm_disarm
```

### AV・その他の機器

```
テレビ・スピーカー・AVアンプ (media_player)
  ON/OFF                turn_on / turn_off
  再生 / 一時停止         media_play / media_pause / media_stop
  曲送り                 media_next_track / media_previous_track
  音量                   volume_set / volume_mute / volume_up / volume_down
  入力切替                select_source（HDMI1 / Spotify …）
  音場モード              select_sound_mode
  再生指定                play_media（URL・プレイリスト・TTS 読み上げ）

赤外線リモコン (remote)
  ON/OFF                turn_on / turn_off
  任意のコマンド送信       send_command（学習済みのボタンを撃つ）
  学習                   learn_command
  ※ climate や media_player に載らない機器（照明のリモコン等）の受け皿

ロボット掃除機 (vacuum)
  開始 / 一時停止         start / pause
  停止                   stop
  充電台に戻る            return_to_base
  部分清掃                clean_spot
  本体を鳴らす            locate（見失ったとき）
  吸引力                  set_fan_speed

ロボット芝刈り機 (lawn_mower)
  開始 / 一時停止 / 帰還   start_mowing / pause / dock

サイレン・ブザー (siren)
  鳴らす / 止める         turn_on / turn_off
  音色・音量・鳴動時間      tone / volume_level / duration

カメラ (camera)
  ライブ映像              HLS / WebRTC ストリーム
  静止画                  snapshot
  ON/OFF                turn_on / turn_off
```

### 読み取り専用（操作できない）

```
センサー (sensor)
  温度・湿度・気圧・CO2・照度・騒音
  消費電力・積算電力・ガス・水道
  バッテリー残量
  ※ 数値。押せる見た目にしないこと

バイナリセンサー (binary_sensor)
  人感・モーション
  ドア・窓の開閉
  水漏れ・煙・結露
  在宅判定・動作中フラグ

在室・位置 (person / device_tracker)
  在宅 / 外出

天気 (weather)
  現在の天気・気温・予報
```

### 設定値を持つだけの箱（ヘルパー）

```
数値 (number / input_number)          set_value      例: 照明の既定の明るさ
選択 (select / input_select)          select_option  例: 運転モードの候補
トグル (input_boolean)                turn_on/off    例: 「来客モード」フラグ
文字列・日時 (text / datetime)          set_value      例: タイマー時刻
```
