# Tera Term Mac

<img src="macos/docs/icon.png" width="96" align="right" alt="">

**Tera Term の macOS 版です。** シリアル通信・SSH・Telnet・TTL マクロ・TeraTerm Menu (接続先ランチャー) が Mac で使えます。

> **非公式版です。** TeraTerm Project とは関係のない個人の移植で、TeraTerm Project の公認・支援を受けたものではありません。不具合や要望は本家ではなく、このリポジトリの Issues へお願いします。

- ダウンロード: **[最新版 (クリックでダウンロード)](https://github.com/satorunet/teraterm_macos/releases/latest/download/TeraTermMac.dmg)** — `TeraTermMac.dmg` (過去の版は [Releases](https://github.com/satorunet/teraterm_macos/releases) から)
- 更新情報: 各版で変わったことや更新状況は **[Releases の一覧](https://github.com/satorunet/teraterm_macos/releases)** にまとめています (アプリの「Tera Term Mac について」→「更新情報」からも開けます)
- ソース: [`macos/`](macos/) (Swift / AppKit)
- ライセンス: **MIT** ([macos/LICENSE](macos/LICENSE))
- 対応: macOS 11 以降 (Apple Silicon / Intel)

## インストール

1. 上の「最新版」から `TeraTermMac.dmg` をダウンロードして開く
2. 「Tera Term Mac」のアイコンを「アプリケーション」へドラッグ

Apple の公証済みなので、そのまま起動できます。

## アンインストール

Tera Term Mac のメニュー →「Tera Term Mac をアンインストール…」
(アプリ本体・設定と接続リスト・保存したパスワードを選んで削除できます)

## できること

| 機能 | 内容 |
|---|---|
| 接続 | シリアルポート / SSH / Telnet / 生 TCP / ローカルシェル |
| 端末 | VT100 / xterm 互換、256 色・TrueColor、UTF-8 / Shift_JIS / EUC-JP、日本語入力 |
| TeraTerm Menu | メニューバーに常駐する接続先ランチャー。自動ログイン、ttpmenu.ini の読み込み・書き出し |
| 設定 | Windows の TERATERM.INI を読み込み、配色かんたん設定 (Terminal.app のプロファイルも) |
| マクロ | Tera Term の TTL マクロ (全命令、Windows 版のマクロがそのまま動く)、`/M=` での起動 |

詳しくは [macos/README.md](macos/README.md) を見てください。

## このリポジトリについて

[TeraTermProject/teraterm](https://github.com/TeraTermProject/teraterm) の fork です。

- **`macos/`** — Tera Term Mac (このプロジェクト)。**MIT License**
- それ以外 — 元の Tera Term (Windows 版) のソース。元のライセンス ([LICENSE.md](LICENSE.md), BSD 3-Clause) のまま
  - 元の README は [README.teraterm.md](README.teraterm.md) にあります

アイコンは Tera Term (© T. Teranishi / TeraTerm Project, BSD License) のものを使っています。

かつて Macintosh 用の Tera Term Mac (Ver 1.6) があり、その著作者は T. Teranishi (寺西 高) 氏です。このリポジトリの Tera Term Mac は、それとは別に今の Tera Term をもとに作り直したものです。
