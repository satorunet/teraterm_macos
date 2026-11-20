# TeraMac — Tera Term の macOS 版

Tera Term の主な機能を Swift / AppKit で macOS 用に作り直したものです。
(元の Tera Term は Win32 API で書かれているため、Mac ではそのまま動きません。)

## できること

| 機能 | 内容 |
|---|---|
| 接続 | **シリアルポート** (`/dev/cu.*`、速度・データ長・パリティ・ストップビット・フロー制御、送信遅延、ブレーク信号) / **SSH** (macOS の `ssh` を使用、パスワード自動入力・秘密鍵指定) / **Telnet** (オプション交渉・NAWS) / 生 TCP / ローカルシェル |
| 端末 | VT100 / xterm 互換 (256 色・TrueColor、代替画面、スクロール領域、DEC 罫線、ブラケットペースト、マウス報告) |
| 日本語 | UTF-8 / Shift_JIS / EUC-JP、全角文字、日本語入力 (IME)、あいまい幅の切り替え |
| 操作 | 選択で自動コピー、右クリックで貼り付け、複数行貼り付けの確認、スクロールバック、タブ |
| ログ | 受信データの保存 (時刻付きも可)、ファイル送信 |
| マクロ | TTL マクロの主な命令 (`connect` `send` `sendln` `wait` `waitln` `if/elseif/else/endif` `while` `for` `do/loop` `goto` `call` `messagebox` `inputbox` `passwordbox` `logopen` `strconcat` `sprintf2` ほか) |
| 設定 | 端末サイズ、文字コード、改行コード (送信/受信)、ローカルエコー、BS キー、Option を Meta に、フォント、配色 |

## TeraTerm Menu (メニューバー常駐ランチャー)

Windows 版の TeraTerm Menu (ttpmenu) を標準で組み込んでいます。タスクトレイの代わりに **メニューバーの端末アイコン** に常駐します。

- **左クリック**: 登録した接続先の一覧 → 選ぶと新しいウインドウで接続
- **右クリック**: リスト設定 / 大きいアイコンで表示 / フォント指定 / 左クリックで一覧を表示 / ホットキー (⌃⌥M) で一覧を表示 / Mac にログインしたら起動 / バージョン情報 / 実行 / 終了
- **ホットキー ⌃⌥M** (Windows 版の Ctrl+Alt+M) で、マウスの位置に一覧を表示
- 一覧は Dock アイコンの右クリック、アプリの「接続先」メニューからも開けます

**リスト設定** (Windows 版と同じ構成):

| 項目 | 内容 |
|---|---|
| 名前 / ホスト名 | `ホスト名:ポート番号` でポート指定 |
| 起動方法: 自動ログイン | ユーザー名・パスワード・SSH を使う・鍵ファイル。Telnet ではプロンプトを待ってユーザー名とパスワードを送る |
| 起動方法: マクロファイル指定 | 接続してから TTL マクロを実行 |
| 起動方法: 起動のみ | 接続だけ |
| 詳細 | ログファイル (`%Y%m%d` などで日時)、ユーザー名プロンプト、パスワードプロンプト、オプション (`/KR=SJIS /KT=SJIS` で文字コード、`/C= /BAUD=` でシリアル、`/T=0` で生 TCP など) |
| 起動時に実行 | TeraMac の起動時に自動で接続 |

パスワードは Windows 版の LockBox の代わりに **macOS のキーチェーン** に暗号化して保存します。
ウインドウを全部閉じてもメニューバーに残ります (終了はメニューバーの右クリック →「終了」か ⌘Q)。

## ビルド

Xcode (コマンドラインツール) が入った Mac で:

```sh
cd macos
./scripts/bundle.sh          # build/TeraMac.app ができる
open build/TeraMac.app
swift test                   # 端末エミュレータとマクロのテスト
```

## コマンドライン (Tera Term と似た書き方)

```sh
TeraMac.app/Contents/MacOS/TeraMac host:22 /ssh /user=root
TeraMac.app/Contents/MacOS/TeraMac host /telnet
TeraMac.app/Contents/MacOS/TeraMac /C=/dev/cu.usbserial-XXXX /BAUD=115200
TeraMac.app/Contents/MacOS/TeraMac /M=~/macro.ttl
```

`.ttl` ファイルを TeraMac で開くとマクロが実行されます。

## 主なショートカット

| キー | 操作 |
|---|---|
| ⌘⇧N | 新しい接続 |
| ⌘N / ⌘T | 新しいウインドウ / ローカルシェル |
| ⌘D | 接続を複製 |
| ⌘L | ログ開始・停止 |
| ⌘B | ブレーク信号 |
| ⌘R | 再接続 (切断後に Enter でも再接続) |
| ⌘⇧M / ⌘. | マクロ実行 / 停止 |
| ⌘, | 端末の設定 |
| Shift + PageUp/PageDown | スクロールバック |

## ソースの構成

- `Sources/TeraCore/` — 端末エミュレータ (`Terminal.swift`)、文字コード、文字幅、TTL マクロ (`TTL.swift`)。AppKit に依存しない
- `Sources/TeraMac/` — アプリ本体 (画面描画・キー入力・接続・ダイアログ)
- `Tests/TeraCoreTests/` — テスト

`TERAMAC_SNAPSHOT=<フォルダ>` を付けて起動すると、画面・ダイアログを PNG に書き出して終了します (見た目の確認用)。

## ライセンス

Tera Term と同じ BSD ライセンス (リポジトリ直下の `LICENSE.md`) に従います。
