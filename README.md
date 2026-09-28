# Remixa

Remixa は macOS 用のネイティブ音楽リミックスアプリです。Swift 6 / SwiftUI で作られています。

## 概要

- DJ 風の音源編集（v0.1）
- シンプルなマルチトラック DAW（v0.2, 予定）
- AI によるステム分離（v0.3, 予定。モデルは初回利用時にダウンロードされ、アプリには同梱されません）

### v0.1 の主な機能

- 音声ファイル（mp3, m4a, wav, aiff, flac）を開く（ファイル選択 / ドラッグ&ドロップ）
- 波形表示、再生位置表示、ズーム、クリックでシーク、ドラッグで範囲選択
- 再生/一時停止（スペースキー）、停止、選択範囲のループ再生
- テンポ変更（50〜200%、ピッチ非変化）、ピッチシフト（±12半音）、簡易 BPM 自動推定
- カット/削除、選択範囲へのトリム、Undo/Redo（Cmd+Z / Shift+Cmd+Z）、フェードイン/アウト
- エフェクトラック（3バンド EQ、ローパス/ハイパスフィルタ、リバーブ、ディレイ、ディストーション。各バイパス・パラメータ調整可）
- WAV / M4A へのオフライン書き出し（編集・エフェクト・テンポ・ピッチをすべて反映、進捗表示あり）

## インストール（Releases から）

1. [Releases](https://github.com/uyuk216/Remixa/releases) ページから最新の `Remixa.dmg` をダウンロードします。
2. DMG を開き、`Remixa.app` を `アプリケーション` フォルダにドラッグします。

### 初回起動時の Gatekeeper 対応

Remixa は Apple Developer ID での署名を行っていない（ad-hoc 署名）ため、初回起動時に「開発元を確認できないため開けません」と表示されることがあります。以下のいずれかの方法で開いてください。

- **方法A**: Finder で `Remixa.app` を **右クリック（または Control+クリック）→「開く」** を選択し、表示されるダイアログで「開く」を選択します。
- **方法B**: ターミナルで隔離属性を削除します。

  ```sh
  xattr -dr com.apple.quarantine /Applications/Remixa.app
  ```

## アップデート

Remixa は起動時に自動的にアップデートを確認します（[Sparkle](https://sparkle-project.org/) を使用）。メニューの「Remixa」→「アップデートを確認…」からも手動で確認できます。

## ビルド方法

### 必要環境

- Xcode 15 以降（macOS 14+ SDK）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

### 手順

```sh
git clone https://github.com/uyuk216/Remixa.git
cd Remixa
xcodegen generate   # project.yml から Remixa.xcodeproj を再生成する場合
xcodebuild -project Remixa.xcodeproj -scheme Remixa -configuration Debug build
```

生成済みの `Remixa.xcodeproj` はリポジトリにコミットされているため、`xcodegen` がなくても `xcodebuild` でビルドできます。

## ロードマップ

- **v0.1**（本リリース）: DJ 風の波形編集、テンポ/ピッチ変更、エフェクトラック、書き出し
- **v0.2**: シンプルなマルチトラック DAW
- **v0.3**: AI によるステム分離（モデルは初回利用時にダウンロード）

## ライセンス

MIT License. 詳細は [LICENSE](./LICENSE) を参照してください。
