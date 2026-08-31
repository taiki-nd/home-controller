# リリース戦略 / ブランチ運用

home-ctl を一般公開するにあたっての、ブランチ・タグ・機能フラグの運用方針。

- 作成日: 2026-08-04
- 対象: `main` / `.github/workflows/ios-testflight.yml` / `makefile`
- 前提: **v1 系 = home-ctl 本体（Home Assistant 連携）／ Spotify は v2 で公開**

---

## 0. これからやること

| # | やること | 場所 | 済 |
|---|---|---|---|
| 1 | ~~`ENABLE_MUSIC` フラグを実装（§3）~~ | `app/lib/services/app_flags.dart` | ✅ |
| 2 | ~~CI にタグ prefix → フラグの分岐を足す（§4）~~ | `.github/workflows/ios-testflight.yml` | ✅ |
| 3 | ~~`makefile` に `ENABLE_MUSIC ?= true` を足す（§4）~~ | `makefile` | ✅ |
| 4 | ~~`SPOTIFY_CLIENT_ID` 必須チェックを条件付きにする（§4）~~ | 同 workflow | ✅ |
| 5 | v1.0.0 の中身を Milestone + Issue に起こす（§2） | GitHub | |
| 6 | Spotify の extended quota を申請（§5） | Spotify Developer Dashboard | |

---

## 1. 結論

| | やること |
|---|---|
| ブランチ | **`main` 1 本。** 作業は短命の `feat/xxx` を切って PR → squash merge → 削除 |
| バージョン | **タグで表す**（`ios-v1.0.0`）。ブランチ名には入れない |
| v1.1.0 の中身 | **ブランチではなく GitHub Milestone + Issue** |
| Spotify の出し分け | **ブランチではなくコンパイル時フラグ**（`--dart-define=ENABLE_MUSIC`） |
| 長期ブランチ | 原則作らない。**例外は §6 の hotfix のみ** |

```
main ──●──●──●──●──●──●──●──▶
       │        │        │
   feat/ha-   feat/home- ios-v1.0.0（タグ）
   client     tiles
```

---

## 2. なぜ `feature/v1.0.0` のような長期ブランチにしないか

### 2-1. バージョンの正はすでにタグ側にある

`ios-testflight.yml` は `ios-v*` / `ios-test-v*` のタグ push で起動し、
**タグ名から `--build-name` を切り出している**（`name="${GITHUB_REF_NAME##*v}"`）。
`ios-test-v1.0.8` まで実績もある。

ここでブランチ名にもバージョンを持たせると、**同じ番号を 2 か所で管理**することになる。

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

## 4. タグの 2 系統でビルドを出し分ける

workflow のコメントには `ios-test-v*` は「反復用。中身は同じ。系統を分けるための
プレフィックス」とあるが、**ここに差をつける。**

| タグ | `ENABLE_MUSIC` | 用途 |
|---|---|---|
| `ios-test-v1.0.9` | **true** | 自分・内輪用。TestFlight の Internal Testing で配る。**Spotify が使える** |
| `ios-v1.0.0` | **false** | App Store 公開用。**これを審査に出す** |

追加の運用は増えない。**打つタグを変えるだけ。**

成立する理由:

- **TestFlight の Internal Testing は App Review 不要**（設計メモ §11）。
  Spotify 入りビルドをいつでも自分の iPad に入れられる
- 公開版は `ENABLE_MUSIC=false` の**別ビルド**。同じバイナリではないので、
  審査対象に Spotify 機能が含まれない

**`UIBackgroundModes: audio` も同じ扱いにする**（issue #8）。QOBUZ で別のアプリを
開いてもキューを進めるために無音を鳴らし続けているが、`ENABLE_MUSIC=false` の
ビルドには QOBUZ 自体が入らない。**音を出さないアプリが audio を宣言している
だけの状態は審査で刺さる**ので、CI が公開ビルドの Info.plist からこのキーを
`PlistBuddy -c Delete` で抜く（`Drop background audio mode from the public build`）。
Info.plist の配列は xcconfig で条件分岐できないため、ビルド前の一手で処理している。

### CI の変更

```yaml
- name: Resolve flags
  id: flags
  run: |
    if [[ "${GITHUB_REF_NAME}" == ios-test-v* ]]; then
      echo "enable_music=true" >> "$GITHUB_OUTPUT"
    else
      echo "enable_music=false" >> "$GITHUB_OUTPUT"
    fi
```

`Prepare Flutter iOS build config` の `flutter build ios` に
`--dart-define=ENABLE_MUSIC=${{ steps.flags.outputs.enable_music }}` を足す。

**同じ step の `SPOTIFY_CLIENT_ID` 必須チェック（未設定なら `exit 1`）を
条件付きにすること。** `ENABLE_MUSIC=false` のときに Client ID を要求すると
公開ビルドが通らない。

`makefile` 側は `ENABLE_MUSIC ?= true` を既定にして `DART_DEFINES` に足す。
**手元の `make app-run` は今までどおり Spotify が使える。**

### ビルド番号は触らなくてよい

CI が `github.run_number + RUN_NUMBER_OFFSET` で採番しているので、
**2 系統のタグが同じアプリレコード（`app.home-ctl`）に上がっても単調増加が
自動で担保される。** 手動の付け替えは不要。

「バージョン名は下がるのにビルド番号は上がる」という見た目になるが
（`ios-test-v1.0.9` の次に `ios-v1.0.0` を出す場合など）、
App Store Connect 的には問題ない。

---

## 5. Spotify 側の承認が v2 のボトルネック

**Spotify Web API のアプリは development mode だと登録した 25 ユーザーしか
使えない。** 一般公開には extended quota mode の申請と、Spotify のデザイン
ガイドライン遵守（ロゴの出し方、Spotify のコンテンツである旨の明示など）が要る。

つまり「v1 は home 単体で出す／ Spotify は v2」は**実装の都合ではなく外部の
承認待ちが理由**であり、**いつ下りるか読めない。**

読めない待ち時間を長期ブランチで跨ぐのが、まさに §2-2 の腐らせるパターン。
フラグなら**承認が下りた日にタグを打つだけ**で済む。

内輪配布は 25 ユーザー枠に収まるので、申請前でも `ios-test-v*` は普通に使える。

---

## 6. 長期ブランチを切っていい唯一のケース

**v1.0.0 を出荷したあと、v1.1.0 の開発中に v1.0.x の hotfix が要るとき**だけ
`release/1.0.x` を切る。

**必要になってから切る**のがポイント。最初から用意しない。

---

## 7. リリース手順

```bash
# 1. 作業
git switch -c feat/ha-client
# … 実装 …
# PR → squash merge → ブランチ削除

# 2. 手元・内輪に配る（Spotify 入り）
git tag ios-test-v1.0.9 && git push origin ios-test-v1.0.9

# 3. 公開ビルド（home 単体）
git tag ios-v1.0.0 && git push origin ios-v1.0.0
# → TestFlight に上がったビルドを App Store Connect から審査に出す
```

`app/pubspec.yaml` の `version:` は、タグ起動なら CI が `--build-name` で
上書きするので必須ではないが、`workflow_dispatch` 時のフォールバックになるので
リリース時に合わせて更新しておくとよい。
