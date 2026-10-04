# Remixa

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/uyuk216)

Remixa は macOS 用のネイティブ音楽リミックスアプリです。Swift 6 / SwiftUI で作られています。

## 概要

- DJ 風の音源編集（v0.1）
- シンプルなマルチトラック DAW（v0.2）
- AI によるステム分離（v0.3。モデルは初回利用時にダウンロードされ、アプリには同梱されません）
- クリップ単位のテンポ同期（v0.4）
- マーカー、メトロノーム、複数選択、非破壊ピッチ変更、ステム書き出し（v0.5）

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

- `.remixa` はアトミックな `FileWrapper` 書き込みではなく通常のディレクトリへのコピーで保存されるため、保存中の強制終了に対する耐性は限定的です

### v0.3 の主な機能（AI パート分離）

- クリップを選択して「パート分離」を実行すると、[Demucs](https://github.com/facebookresearch/demucs)（Meta 製、MIT ライセンス）による AI 音源分離でボーカル・ドラム・ベース・その他のパートに分離し、それぞれ新しいトラックとして追加します
- **初回利用時のみ**、分離環境（Python ランタイムと Demucs モデル、合計約 1GB）を `~/Library/Application Support/Remixa/stems` にダウンロードします。アプリ本体には同梱されません。ダウンロード中は進捗が表示され、完了後は再ダウンロードなしで繰り返し使えます
- 分離処理はローカルで実行されるため、音声ファイルが外部に送信されることはありません
- Demucs は MIT License で提供されています。クレジット: Meta AI Research (Demucs)

#### CLI / MCP からのパート分離

```sh
remixa stems status                    # AI パート分離環境の状態（notInstalled/installing/ready/failed）
remixa stems install                   # 環境をインストール（初回のみ、完了まで待機）
remixa stems separate <clipId>         # 指定クリップをパート分離（完了まで待機）
remixa split ~/Music/song.wav          # 音声を追加してすぐパート分離（完了まで待機）
```

MCP からは `stems_status` / `stems_install` / `stems_separate` ツールとして呼び出せます。いずれも初回は約 1GB のダウンロードが発生し得るため、`stems_install` と `stems_separate`（および `export_mix`）は完了まで最大 30 分程度ブロックする可能性があります。

### v0.4 の主な機能（クリップ単位のテンポ同期）

- クリップごとにテンポ倍率（0.5〜2.0）を設定できます。ピッチを保ったまま再生・書き出しでき、タイムライン上の長さも倍率に合わせて変わります
- 「BPM に合わせる」でクリップの元 BPM からプロジェクト BPM に同期できます。元 BPM が未設定なら音源から推定して保存します。同期を有効にしたクリップは、プロジェクト BPM の変更にも追従します
- 拍グリッドへの開始位置スナップと、クリップ内の音源内容を ±10 ms / ±1 拍ずらすナッジに対応します
- テンポ倍率と元 BPM はクリップ上に表示され、編集シートから同期設定を変更できます。テンポ設定は保存・読み込み、Undo/Redo、トリム、分割、複製にも保持されます

### v0.5 の主な機能

- クリップは Command+クリックで複数選択、Shift+クリックで範囲選択できます。選択したクリップをまとめて移動・複製・削除できます。トラックへの音声ドロップは落とした位置に配置され、複数ファイルもすべて読み込みます。クリップ編集シートはトリム範囲の音声だけを編集対象にします
- 名前付きマーカーの追加、移動、名前変更、削除ができ、プロジェクト保存と Undo/Redo に対応します。マーカーをクリックするとその位置へ移動します
- 拍子は 4/4 または 3/4、スナップは 1/4拍・1/2拍・1拍・1小節・オフから選べます。「全体を表示」「選択範囲に合わせる」「再生位置へ移動」と、再生中の再生ヘッド自動スクロールを追加しました
- 再生用・書き出し用メトロノームを個別にオン/オフできます。クリック音量を調整でき、再生時には1小節のカウントインを設定できます
- クリップのトリム範囲をクロマと Krumhansl プロファイルで簡易解析し、推定キーを表示します。クリップごとのピッチを±12半音で非破壊変更し、検出キーをプロジェクトキーへ合わせられます。ピッチ変更はテンポ同期と同じ再生・書き出し経路で処理されます
- よく使う編集操作をメニューに追加しました: 分割 (⌘B)、複製 (⌘D)、削除 (Delete)、拡大/縮小 (⌘+/⌘−)、全体表示 (⌘0)、選択範囲表示 (⇧⌘0)、再生位置へ移動 (⌘J)、先頭へ移動 (Home/Return)
- 書き出しは WAV 24-bit PCM / 32-bit float、M4A 128 / 192 / 256 / 320 kbps を選べます。トラック別に一括書き出しでき、メトロノームは別のステムになります

#### v0.5 CLI / MCP 操作

```sh
remixa snap halfBeat 3/4
remixa metronome playback on
remixa metronome export on
remixa metronome count-in on
remixa metronome volume 0.6
remixa key Cメジャー
remixa clip-key <clipId>
remixa marker-add 32 "サビ"
remixa marker-update <markerId> --name "ラスサビ" --time 48
remixa marker-remove <markerId>
remixa export ~/Desktop/mix.wav --wav float32
remixa export ~/Desktop/mix.m4a --m4a-bitrate 320000
remixa export-stems ~/Desktop/stems wav --wav float32
remixa call clip.update '{"clipId":"...","pitchSemitones":-2,"matchProjectKey":true}'
```

MCP では `project_set_timeline_settings`、`project_set_metronome`、`project_set_key`、`marker_add` / `marker_update` / `marker_remove`、`clip_detect_key`、`export_mix`、`export_stems` を利用できます。クリップのピッチは `clip_update` の `pitchSemitones`、キー合わせは `matchProjectKey` で指定します。エクスポートの品質は WAV で `wavEncoding` (`pcm24` / `float32`)、M4A で `m4aBitrate` (`128000` / `192000` / `256000` / `320000`) を指定できます。

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
remixa call clip.update '{"clipId":"...","tempoRate":1.1,"sourceBPM":120,"syncToProject":true}'
remixa call clip.syncTempo '{"clipId":"..."}'  # プロジェクト BPM に合わせて同期
remixa call automation.set '{"trackId":"...","parameter":"volume","points":[{"time":0,"value":1},{"time":8,"value":0.6}]}'
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
- **v0.3**（本リリース）: AI によるステム分離（Demucs、モデルは初回利用時にダウンロード）、CLI/MCP からの `stems status`/`install`/`separate` 操作
- **v0.4**: クリップ単位のテンポ同期、プロジェクト BPM への自動追従、拍スナップとナッジ、CLI/MCP の `clip.update` / `clip.syncTempo` 操作
- **v0.5**: 名前付きマーカー、メトロノーム/カウントイン、拍子・スナップ選択、複数クリップ編集、キー検出/非破壊ピッチ、WAV/M4A品質選択とステム書き出し、CLI/MCP 制御

## ライセンス

MIT License. 詳細は [LICENSE](./LICENSE) を参照してください。

## 支援

Remixa が役に立ったら [GitHub Sponsors](https://github.com/sponsors/uyuk216) で支援していただけると開発の励みになります。
