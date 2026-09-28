# Remixa

Remixa は macOS 用のネイティブ音楽リミックスアプリです。Swift 6 / SwiftUI で作られています。

## 概要

- DJ 風の音源編集（v0.1）
- シンプルなマルチトラック DAW（v0.2）
- AI によるステム分離（v0.3, 予定。モデルは初回利用時にダウンロードされ、アプリには同梱されません）

### v0.1 の主な機能

- 音声ファイル（mp3, m4a, wav, aiff, flac）を開く（ファイル選択 / ドラッグ&ドロップ）
- 波形表示、再生位置表示、ズーム、クリックでシーク、ドラッグで範囲選択
- 再生/一時停止（スペースキー）、停止、選択範囲のループ再生
- テンポ変更（50〜200%、ピッチ非変化）、ピッチシフト（±12半音）、簡易 BPM 自動推定
- カット/削除、選択範囲へのトリム、Undo/Redo（Cmd+Z / Shift+Cmd+Z）、フェードイン/アウト
- エフェクトラック（3バンド EQ、ローパス/ハイパスフィルタ、リバーブ、ディレイ、ディストーション。各バイパス・パラメータ調整可）
- WAV / M4A へのオフライン書き出し（編集・エフェクト・テンポ・ピッチをすべて反映、進捗表示あり）

### v0.2 の主な機能（簡易 DAW）

- マルチトラックのタイムライン：トラックの追加/削除/名前変更、プロジェクト BPM に基づく小節/拍グリッド
- クリップ操作：音声ファイルのドラッグ&ドロップまたは開くパネルで配置、ドラッグで移動（グリッドスナップ切替あり）、端をドラッグしてトリム、再生位置での分割、複製、削除、クリップごとのゲイン/フェードイン・アウト
- トラックごとのボリューム/パン/ミュート/ソロと、v0.1 と共通のエフェクトラック（EQ・フィルタ・リバーブ・ディレイ・ディストーション）。マスターボリュームあり
- AVAudioEngine によるアレンジ全体のサンプル同期再生、再生位置表示、タイムライン上のループ範囲、スペースキーで再生/一時停止、ズーム
- クリップをダブルクリックすると v0.1 の単体エディタ（波形・テンポ/ピッチ・カット/トリム/フェード・エフェクト）が開き、そのクリップの音声を直接編集可能
- タイムライン操作の Undo/Redo
- プロジェクトの保存/読み込み：`.remixa` パッケージ形式（JSON + 参照音声ファイルをコピーして同梱、Finder からダブルクリックで開ける）。Cmd+S / Cmd+O 対応、Open Recent 登録
- ミックス全体のオフライン書き出し（WAV/M4A、進捗表示）
- v0.3 でステム分離結果を新規トラックとして追加できるよう、`RemixaProject.addTrack(named:audioURL:)` という単純な API を用意

#### v0.2 の既知の制限

- タイムライン上ではクリップの再生速度・ピッチは変更されません（テンポ/ピッチ変更は v0.1 の単体エディタでクリップを開いて適用してください）
- `.remixa` はアトミックな `FileWrapper` 書き込みではなく通常のディレクトリへのコピーで保存されるため、保存中の強制終了に対する耐性は限定的です

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

## AI連携（Claude Code / Codex）

Remixa には `remixa` コマンドラインツールが同梱されています（`Remixa.app/Contents/Helpers/remixa`）。Remixa アプリと Unix ドメインソケット（`~/Library/Application Support/Remixa/control.sock`）経由の JSON-RPC で通信し、アプリが起動していなければ自動的に起動して待機します。CLI としても、Claude Code や Codex から使う MCP（Model Context Protocol）サーバとしても動作します。

### CLI としてインストール

```sh
/Applications/Remixa.app/Contents/Helpers/remixa install-cli
```

`/usr/local/bin` または `~/.local/bin` に `remixa` へのシンボリックリンクを作成します。以後はそのまま `remixa` コマンドとして使えます。

### CLI 使用例

```sh
remixa status                          # アプリの状態を表示（未起動なら自動起動）
remixa open ~/Music/song.remixa        # プロジェクトを開く
remixa add ~/Music/vocal.wav --track "Vocal"  # トラックに音声を追加
remixa bpm 128                         # BPM を設定
remixa play                            # 再生
remixa stop                            # 停止
remixa seek 12.5                       # 12.5 秒にシーク
remixa export ~/Desktop/mix.wav        # ミックスを書き出し
remixa analyze ~/Music/loop.wav        # 音声ファイルを解析
remixa state                           # プロジェクト全体の状態を JSON で取得
remixa call track.update '{"trackId":"...","volume":0.8}'  # 任意の RPC を直接呼ぶ
```

### Claude Code から使う

```sh
claude mcp add remixa -- /Applications/Remixa.app/Contents/Helpers/remixa mcp
```

登録後は Claude Code の会話の中で「BPM を 128 にして」「トラックにボーカルを追加して」のように指示すると、Remixa アプリを直接操作できます。

### Codex から使う

`~/.codex/config.toml` に以下を追加します。

```toml
[mcp_servers.remixa]
command = "/Applications/Remixa.app/Contents/Helpers/remixa"
args = ["mcp"]
```

### アプリ内 AI アシスタントについて

Remixa アプリ自体にも AI アシスタント機能があり、アプリ内のチャットからこれと同じ操作（トラック追加、BPM 変更、エフェクト調整、書き出しなど）を指示できます。`remixa mcp` / `remixa call` は同じ制御ソケットを外部の AI エージェント（Claude Code や Codex）から利用するための窓口です。

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

- **v0.1**: DJ 風の波形編集、テンポ/ピッチ変更、エフェクトラック、書き出し
- **v0.2**（本リリース）: シンプルなマルチトラック DAW（タイムライン、クリップ編集、トラックミキサー、プロジェクト保存/読み込み、ミックス書き出し）
- **v0.3**: AI によるステム分離（モデルは初回利用時にダウンロード）

## ライセンス

MIT License. 詳細は [LICENSE](./LICENSE) を参照してください。
