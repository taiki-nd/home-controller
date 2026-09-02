# リリース戦略 / ブランチ運用

home-ctl を一般公開するにあたっての、ブランチ・タグ・機能フラグの運用方針。

- 作成日: 2026-08-04
- 対象: `main` / `makefile`
- 2026-09-02: **GitHub Actions での配信をやめた。** `.github/workflows/ios-testflight.yml`
  とタグ用の make ターゲット（`ios-tag-*` / `ios-test-tag-*`）を削除し、配信は手元の
  `make ios-ship` 1 本にした（§7）
- 前提: **v1 系 = home-ctl 本体（Home Assistant 連携）／ Spotify は v2 で公開**

---

## 0. これからやること

| # | やること | 場所 | 済 |
|---|---|---|---|
| 1 | ~~`ENABLE_MUSIC` フラグを実装（§3）~~ | `app/lib/services/app_flags.dart` | ✅ |
| 2 | ~~CI にタグ prefix → フラグの分岐を足す（§4）~~ CI ごと廃止 | ~~`.github/workflows/ios-testflight.yml`~~ | ✅ |
| 3 | ~~`makefile` に `ENABLE_MUSIC ?= true` を足す（§4）~~ | `makefile` | ✅ |
| 4 | ~~`SPOTIFY_CLIENT_ID` 必須チェックを条件付きにする（§4）~~ 同上 | ~~同 workflow~~ | ✅ |
| 5 | v1.0.0 の中身を Milestone + Issue に起こす（§2） | GitHub | |
| 6 | Spotify の extended quota を申請（§5） | Spotify Developer Dashboard | |

---

## 1. 結論

| | やること |
|---|---|
| ブランチ | **`main` 1 本。** 作業は短命の `feat/xxx` を切って PR → squash merge → 削除 |
| バージョン | **`app/pubspec.yaml` の `version:` と `make ... BUILD_NAME=` で表す。** ブランチ名には入れない（配った印としてタグを打つのは任意） |
| v1.1.0 の中身 | **ブランチではなく GitHub Milestone + Issue** |
| Spotify の出し分け | **ブランチではなくコンパイル時フラグ**（`--dart-define=ENABLE_MUSIC`） |
| 長期ブランチ | 原則作らない。**例外は §6 の hotfix のみ** |

```
main ──●──●──●──●──●──●──●──▶
       │        │        │
   feat/ha-   feat/home- ここで make ios-ship（配信）
   client     tiles
```

---

## 2. なぜ `feature/v1.0.0` のような長期ブランチにしないか

### 2-1. バージョンの正はブランチの外にある

配信時のバージョン名は `make ios-ship BUILD_NAME=1.0.29` で渡し、`app/pubspec.yaml` の
`version:` を同じ番号に合わせておく（CI を使っていた頃はタグ名から `--build-name` を
切り出していた）。

ここでブランチ名にもバージョンを持たせると、**同じ番号を 3 か所で管理**することになる。

### 2-2. v2 に隔離した Spotify コードが確実に腐る（これが決定的）

`docs/home-assistant-integration.md` §10 で決めた home / music の分離は、
**`lib/ui/tablet_layout.dart` → `lib/ui/music/` の移設を伴う。**

v1 側で `AppShell` を作って既存の 8000 行超を動かす一方、v2 ブランチが旧パスの
Spotify コードを抱えたままになる。つまり **v1 が進むほど v2 のマージが不可能に
近づく。** 長期ブランチで一番やってはいけない形。

### 2-3. 修正の二重取り込みが毎回発生する

v1 系で直したバグを v2 にも入れる作業が、リリースのたびに増える。

---

## 3. Spotify はフラグで隠す（消さない）

```
--dart-define=ENABLE_MUSIC=false   # v1 系の公開ビルド
--dart-define=ENABLE_MUSIC=true    # 手元・TestFlight・将来の v2
```

やることは **Drawer の `MUSIC` 項目を出すかどうかだけ。**
§10 で「home と music を最上位で完全分離する」と決めた時点で、
**分離線がそのままフラグの境界になっている。**

| 効果 | 内容 |
|---|---|
| 公開ビルド | `MUSIC` が消えて home 専用アプリになる |
| **コードが腐らない** | 手元では常に両方動く。§2-2 の問題が起きない |
| v2 のコスト | **フラグを true にしてタグを打つだけ。マージ作業ゼロ** |
| シークレット依存 | `false` のときは `SPOTIFY_CLIENT_ID` が不要になる |

### 実行時トグルにしないこと

**必ず `--dart-define` のコンパイル時フラグにする。**

「公開ビルドに機能を入れておいて、審査通過後にサーバ設定で有効化する」形にすると、
App Store のガイドライン **2.3.1（隠し機能）に抵触する。**

コンパイル時フラグなら公開バイナリは**本当に music を実行できない**（コードパスが
到達不能）ので、この問題が起きない。設定画面に出したくなるところだが我慢する。

---

## 4. `ENABLE_MUSIC` でビルドを出し分ける

| コマンド | `ENABLE_MUSIC` | 用途 |
|---|---|---|
| `make ios-ship`（既定） | **true** | 自分・内輪用。TestFlight の Internal Testing で配る。**Spotify が使える** |
| `make ios-ship ENABLE_MUSIC=false` | **false** | App Store 公開用。**これを審査に出す** |

追加の運用は増えない。**渡す変数を変えるだけ。**

成立する理由:

- **TestFlight の Internal Testing は App Review 不要**（設計メモ §11）。
  Spotify 入りビルドをいつでも自分の iPad に入れられる
- 公開版は `ENABLE_MUSIC=false` の**別ビルド**。同じバイナリではないので、
  審査対象に Spotify 機能が含まれない

**`UIBackgroundModes: audio` も同じ扱いにする**（issue #8）。QOBUZ で別のアプリを
開いてもキューを進めるために無音を鳴らし続けているが、`ENABLE_MUSIC=false` の
ビルドには QOBUZ 自体が入らない。**音を出さないアプリが audio を宣言している
だけの状態は審査で刺さる**ので、`make ios-archive` が `ENABLE_MUSIC != true` のとき
このキーを `PlistBuddy -c Delete` で抜く。Info.plist の配列は xcconfig で条件分岐
できないため、archive の前に抜いて後で必ず戻している（使い捨ての CI と違い、
手元では戻さないと作業ツリーに差分が残る）。

`makefile` は `ENABLE_MUSIC ?= true` を既定にして `DART_DEFINES` に足している。
**手元の `make app-run` は今までどおり Spotify が使える。**
`ENABLE_MUSIC=false` のときは `SPOTIFY_CLIENT_ID` を渡さなくてよい。

### ビルド番号は自分で決める

`make ios-ship BUILD_NUMBER=N` の N は手で入れる。**`app/pubspec.yaml` の `+N` は
使われない**（makefile が `--build-number` で上書きする）。

App Store Connect の既存ビルドより大きい数にすること。最後に上げた番号は
ASC の TestFlight 画面か、`GET /v1/builds?filter[app]=…&sort=-uploadedDate` で確かめる。

「バージョン名は下がるのにビルド番号は上がる」という見た目になっても
（内輪版の次に公開版を出す場合など）、App Store Connect 的には問題ない。

---

## 5. Spotify 側の承認が v2 のボトルネック

**Spotify Web API のアプリは development mode だと登録した 25 ユーザーしか
使えない。** 一般公開には extended quota mode の申請と、Spotify のデザイン
ガイドライン遵守（ロゴの出し方、Spotify のコンテンツである旨の明示など）が要る。

つまり「v1 は home 単体で出す／ Spotify は v2」は**実装の都合ではなく外部の
承認待ちが理由**であり、**いつ下りるか読めない。**

読めない待ち時間を長期ブランチで跨ぐのが、まさに §2-2 の腐らせるパターン。
フラグなら**承認が下りた日に配り直すだけ**で済む。

内輪配布は 25 ユーザー枠に収まるので、申請前でも `ENABLE_MUSIC=true` の配信は普通に使える。

---

## 6. 長期ブランチを切っていい唯一のケース

**v1.0.0 を出荷したあと、v1.1.0 の開発中に v1.0.x の hotfix が要るとき**だけ
`release/1.0.x` を切る。

**必要になってから切る**のがポイント。最初から用意しない。

---

## 7. リリース手順

**配信は手元から行う。CI（GitHub Actions）は使わない。**

```bash
# 1. 作業
git switch -c feat/ha-client
# … 実装 …
# PR → squash merge → ブランチ削除

# 2. main を最新にして、pubspec の version: を配る番号に合わせてコミット
git switch main && git pull
cd app && flutter analyze && flutter test && cd ..

# 3. 手元・内輪に配る（Spotify 入り）
make ios-ship SPOTIFY_CLIENT_ID=xxxx ASC_ISSUER_ID=xxxx \
     BUILD_NAME=1.0.29 BUILD_NUMBER=38

# 4. 公開ビルド（home 単体）
make ios-ship ASC_ISSUER_ID=xxxx ENABLE_MUSIC=false \
     BUILD_NAME=1.1.0 BUILD_NUMBER=39
# → TestFlight に上がったビルドを App Store Connect から審査に出す
```

`ios-ship` は `ios-archive` → `ios-export` → `ios-upload` の順に回るだけなので、
**落ちた場所を見たいときは 3 つに分けて実行する。**

`app/pubspec.yaml` の `version:` は `--build-name` に上書きされるが、
`make app-run` など手元の起動では効くので、リリース時に合わせて更新しておく。

### altool が終わらないとき

`xcrun altool` が `WILL RETRY PART N. Checksums do not match.` を延々と繰り返して
進まないことがある（2026-09-02 に発生。1 時間で 6000 回超のリトライ）。
`~/Library/Logs/ContentDelivery/com.apple.itunes.altool/*Upload*.txt` の末尾で分かる。
**待っても抜けないのでプロセスを落として `make ios-upload` をやり直す。**
やり直すと 45 秒で上がった。
