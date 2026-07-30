.DEFAULT_GOAL := help
.PHONY: help app-run app-run-ipad app-mock app-analyze app-test app-clean app-doctor \
        ios-build ios-archive ios-export ios-upload ios-ship \
        icons-install icons-preview icons-adaptive-preview icons-build icons-play icons-font

# SPOTIFY_CLIENT_ID は secret ではないがリポジトリには置かない。
# 環境変数か `make app-run SPOTIFY_CLIENT_ID=xxxx` で渡す。
SPOTIFY_CLIENT_ID ?=
DART_DEFINES = --dart-define=SPOTIFY_CLIENT_ID=$(SPOTIFY_CLIENT_ID)

BUNDLE_ID     = app.home-ctl
PROFILE_NAME  = home-ctl App Store
ASC_KEY_ID    = AD8M84C72U
ASC_ISSUER_ID ?=
BUILD_NAME    ?= 1.0.0
BUILD_NUMBER  ?= 1

help: ## このヘルプを表示
	@grep -hE '^[a-zA-Z0-9_%-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# 開発
# ---------------------------------------------------------------------------

app-run: ## 実機/シミュレータで起動 (例: make app-run SPOTIFY_CLIENT_ID=xxxx)
	cd app && flutter run $(DART_DEFINES)

# Spotify にはつながない。偽の再生状態でデザインだけ見るための入口
# (app/lib/main_mock.dart)。上部バーで枠を切り替えられる。
MOCK_PORT ?= 5860
DEVICE    ?=

app-mock: ## モックデータでデザインをブラウザ表示 (例: make app-mock DEVICE=iphone|ipad)
	cd app && flutter run -d chrome -t lib/main_mock.dart \
		--web-port=$(MOCK_PORT) \
		--web-launch-url "http://localhost:$(MOCK_PORT)/?device=$(DEVICE)"

app-analyze: ## flutter analyze
	cd app && flutter analyze

app-test: ## flutter test
	cd app && flutter test

app-clean: ## flutter clean
	cd app && flutter clean

app-doctor: ## flutter doctor
	flutter doctor

# ---------------------------------------------------------------------------
# App リリースタグ (タグ push で .github/workflows の CI が発火)
#   ios-v*      → iOS CI (TestFlight)
#   ios-test-v* → iOS CI (TestFlight・反復用の系統分離。中身は ios-v* と同じ)
#   TestFlight の Internal Testing 止まり。App Review は不要（設計メモ §11）。
#   反復は ios-test-v* を使い、本番候補だけ ios-v* を打つ。
# ---------------------------------------------------------------------------

ios-tag-%: ## ios-vX.Y.Z を打って push → CI が TestFlight へ (例: make ios-tag-1.0.0)
	git tag ios-v$* && git push origin ios-v$*
ios-untag-%: ## ios-vX.Y.Z をローカル/リモートから削除
	git tag -d ios-v$* && git push origin :ios-v$*
ios-retag-%: ## ios-vX.Y.Z を打ち直して CI 再実行
	git tag -d ios-v$* && git push origin :ios-v$* && git tag ios-v$* && git push origin ios-v$*

ios-test-tag-%: ## ios-test-vX.Y.Z を打って push → CI が TestFlight へ (反復用)
	git tag ios-test-v$* && git push origin ios-test-v$*
ios-test-untag-%: ## ios-test-vX.Y.Z をローカル/リモートから削除
	git tag -d ios-test-v$* && git push origin :ios-test-v$*
ios-test-retag-%: ## ios-test-vX.Y.Z を打ち直して CI 再実行
	git tag -d ios-test-v$* && git push origin :ios-test-v$* && git tag ios-test-v$* && git push origin ios-test-v$*

# ---------------------------------------------------------------------------
# ローカルからの TestFlight 配信（CI が使えないときの手動フォールバック）
#   前提: Apple Distribution 証明書がキーチェーンにあり、
#         auth/home-ctl_AppStore.mobileprovision を
#         ~/Library/MobileDevice/Provisioning Profiles/ に配置済みであること。
#   例: make ios-ship SPOTIFY_CLIENT_ID=xxxx ASC_ISSUER_ID=xxxx BUILD_NUMBER=2
# ---------------------------------------------------------------------------

ios-build: ## Generated.xcconfig と Pods を用意する
	cd app && flutter build ios --release --config-only \
		--build-name=$(BUILD_NAME) --build-number=$(BUILD_NUMBER) $(DART_DEFINES)
	cd app/ios && pod install

ios-archive: ios-build ## Runner.xcarchive を作る（手動署名）
	cd app && rm -rf build/Runner.xcarchive && xcodebuild archive \
		-workspace ios/Runner.xcworkspace \
		-scheme Runner \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath build/Runner.xcarchive \
		PROFILE_NAME="$(PROFILE_NAME)"

ios-export: ## .ipa に書き出す（ExportOptions.plist は書き換えて戻す）
	cd app && /usr/libexec/PlistBuddy \
		-c "Set :provisioningProfiles:$(BUNDLE_ID) $(PROFILE_NAME)" ios/ExportOptions.plist
	cd app && rm -rf build/ipa && xcodebuild -exportArchive \
		-archivePath build/Runner.xcarchive \
		-exportPath build/ipa \
		-exportOptionsPlist ios/ExportOptions.plist; \
	status=$$?; \
	/usr/libexec/PlistBuddy \
		-c "Set :provisioningProfiles:$(BUNDLE_ID) PLACEHOLDER_PROFILE_NAME" ios/ExportOptions.plist; \
	exit $$status

ios-upload: ## .ipa を TestFlight にアップロード（要 ASC_ISSUER_ID）
	@test -n "$(ASC_ISSUER_ID)" || (echo "ASC_ISSUER_ID を渡してください" && exit 1)
	mkdir -p "$$HOME/.appstoreconnect/private_keys"
	cp auth/AuthKey_$(ASC_KEY_ID).p8 "$$HOME/.appstoreconnect/private_keys/"
	cd app && xcrun altool --upload-app \
		-f "$$(ls build/ipa/*.ipa | head -1)" -t ios \
		--apiKey $(ASC_KEY_ID) --apiIssuer $(ASC_ISSUER_ID)

ios-ship: ios-archive ios-export ios-upload ## archive → export → TestFlight を一気に

# ---------------------------------------------------------------------------
# App アイコン (「home.ctl」ワードマーク → SVG → PNG)
#   sonir-workspace/tools/icon-gen と同型。確定案は word-dark。
# ---------------------------------------------------------------------------

icons-install: ## アイコン生成ツールの依存をインストール (初回のみ)
	cd tools/icon-gen && npm install

icons-preview: ## ワードマーク案を 1024px で生成 → tools/icon-gen/preview/
	cd tools/icon-gen && node icon.mjs wordmark

icons-adaptive-preview: ## Android adaptive icon の円マスク合成を確認 (例: make icons-adaptive-preview VARIANT=word-dark)
	cd tools/icon-gen && node icon.mjs adaptive-preview $(VARIANT)

icons-build: ## 確定アイコンを app/ の全プラットフォームへ展開 (Android は adaptive icon も生成。既定 word-dark)
	cd tools/icon-gen && node icon.mjs build $(VARIANT)

icons-play: ## Google Play ストア掲載用ハイレゾアイコン 512x512 → tools/icon-gen/preview/play-icon-*.png
	cd tools/icon-gen && node icon.mjs play-icon $(VARIANT)

icons-font: ## 同梱フォント (Space Grotesk Bold 静的インスタンス) を作り直す
	python3 tools/icon-gen/fonts/make-font.py
