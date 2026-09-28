# リリース手順

このドキュメントは Remixa のリリース（GitHub Actions による自動ビルド・署名・公開）の手順とセットアップ方法をまとめたものです。

## 前提: Sparkle EdDSA 鍵の準備（初回のみ）

Remixa は [Sparkle 2](https://sparkle-project.org/) を使って自動アップデートを行います。アップデートの appcast/DMG は EdDSA 鍵で署名する必要があります。

1. Sparkle の releases ページから配布されているツール一式（`Sparkle-x.y.z.tar.xz`）をダウンロードするか、SPM でチェックアウトされた Sparkle パッケージ内の `bin/generate_keys` を使います。
2. 鍵を生成します。

   ```sh
   ./bin/generate_keys
   ```

   実行すると秘密鍵が macOS のキーチェーンに保存され、対応する **公開鍵（Base64文字列）** が表示されます。

3. 公開鍵を Xcode プロジェクトの `SPARKLE_PUBLIC_KEY` ビルド設定（`Info.plist` の `SUPublicEDKey` に埋め込まれます）に反映します。すでに `project.yml` / プロジェクト設定に反映済みの場合は不要です。
4. 秘密鍵をエクスポートします。

   ```sh
   ./bin/generate_keys -x /tmp/sparkle_private_key.txt
   ```

5. エクスポートした秘密鍵の中身を、GitHub リポジトリの **Settings → Secrets and variables → Actions** から `SPARKLE_PRIVATE_KEY` という名前の Secret として登録します。
6. 公開鍵（Base64文字列）も `SPARKLE_PUBLIC_KEY` という名前の Secret として登録します（ビルド時に `SPARKLE_PUBLIC_KEY` ビルド設定として渡されます）。
7. 秘密鍵のファイル（`/tmp/sparkle_private_key.txt` など）はローカルから削除してください。リポジトリにはコミットしないでください。

## リリースの作成

Remixa のバージョンは Git タグから決定されます。タグ名は `v` + セマンティックバージョン（例: `v0.1.0`）にしてください。

```sh
git tag v0.1.0
git push origin v0.1.0
```

タグを push すると `.github/workflows/release.yml` が起動し、以下を自動的に行います。

1. `Remixa.xcodeproj` を Release 構成でユニバーサルビルド（arm64 + x86_64）
   - `MARKETING_VERSION` はタグから（例: `v0.1.0` → `0.1.0`）
   - `CURRENT_PROJECT_VERSION` は GitHub Actions のビルド番号（`github.run_number`）
   - `SPARKLE_PUBLIC_KEY` は Secrets から埋め込み
2. ビルドした `Remixa.app` に ad-hoc 署名（`codesign --force --deep -s -`）
3. `Remixa.dmg` を作成（`Applications` フォルダへのシンボリックリンク付き）
4. Sparkle の公式リリース（GitHub Releases のアーカイブ）から `sign_update` / `generate_appcast` をダウンロードして取得
5. `SPARKLE_PRIVATE_KEY` を使って更新に署名し、`appcast.xml` を生成
   - `appcast.xml` の enclosure URL は `--download-url-prefix` により
     `https://github.com/uyuk216/Remixa/releases/download/<tag>/Remixa.dmg` を指すようにしています
6. `gh release create` で GitHub Release を作成し、`Remixa.dmg` と `appcast.xml` を添付

リリースが完了すると、既存ユーザーは次回起動時（または「アップデートを確認…」実行時）に自動的に新バージョンを検出します。

## トラブルシューティング

- **appcast の URL が 404 になる**: リリースのタグ名とワークフロー内の `--download-url-prefix` が一致しているか確認してください。
- **アップデートの署名検証に失敗する**: `SPARKLE_PUBLIC_KEY`（アプリ側に埋め込まれた公開鍵）と `SPARKLE_PRIVATE_KEY`（Actions の Secret）が同じ鍵ペアから生成されたものか確認してください。
- **手動でリリースをやり直したい**: 同じタグを再利用せず、新しいバージョン番号のタグを作成してください（GitHub のタグ・リリースは削除してから作り直すことも可能です）。
