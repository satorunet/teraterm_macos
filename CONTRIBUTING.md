# Tera Term Mac への協力のお願い

Tera Term Mac は、Tera Term の macOS 版を作る **個人のプロジェクト** です。
本家の [TeraTerm Project](https://github.com/TeraTermProject/teraterm) とは **別のプロジェクト** で、本家とは関係なく独立して開発しています。

> **Tera Term の原作者 T. Teranishi (寺西 高) 氏の公認を受けた Mac 版のプロジェクトで、Windows 版を開発している TeraTerm Project とは別のチームで開発しています。** ソースは [TeraTermProject/teraterm](https://github.com/TeraTermProject/teraterm) を fork したものです。

**一緒に開発してくれる人を募集しています。** 小さなことでも助かります。

## 連絡先

Tera Term Mac についての連絡は、本家ではなく次のところへお願いします。

- 不具合の報告・要望: [Issues](https://github.com/teraterm-mac/teraterm-mac/issues)
- 質問・相談・「手伝いたい」という連絡: [Discussions](https://github.com/teraterm-mac/teraterm-mac/discussions)
- 修正の提案: [Pull Request](https://github.com/teraterm-mac/teraterm-mac/pulls)

本家の連絡先 (TeraTerm Project のメーリングリストや Discord) には、Mac 版のことは送らないでください。

## 本家との違い

| | Tera Term (本家) | Tera Term Mac (このリポジトリ) |
|---|---|---|
| 対象 | Windows | macOS |
| 開発 | TeraTerm Project | 個人 (satorunet) と協力者 |
| ソース | 本家のリポジトリ | [`macos/`](macos/) (Swift / AppKit) |
| ライセンス | BSD 3-Clause | MIT |

- Mac 版の不具合や要望は、本家ではなく **このリポジトリの [Issues](https://github.com/teraterm-mac/teraterm-mac/issues)** へお願いします。
- Windows 版の不具合や要望は、本家へお願いします。
- このリポジトリの `macos/` 以外は、本家のソースの写しです。ここで直しても本家には入りません。本家を直したいときは、本家に送ってください。

## 手伝ってほしいこと

- 実際の機器での確認: シリアル機器、TEK ホスト、プロキシ、いろいろな SSH サーバー
- Windows 版のマクロ (TTL) や TERATERM.INI が、Mac 版でそのまま動くかの確認
- 不具合の報告と修正、使いにくいところの指摘
- 本家と動きが違うところの指摘
- ドキュメントの不備の指摘、修正

## 不具合の報告 (Issue)

次のことを書いてもらえると助かります。

- Tera Term Mac の版 (「Tera Term Mac について」に出ます)
- macOS の版、Mac の種類 (Apple Silicon / Intel)
- 接続の種類 (SSH / Telnet / シリアル / ローカルシェル)
- 再現の手順と、期待した動き
- 使ったマクロや TERATERM.INI があれば、その該当部分 (パスワードなどは消してください)

## 修正を送る (Pull Request)

1. このリポジトリを Fork して clone します
2. `macos/` でビルドとテストをします (Xcode のコマンドラインツールが要ります)
   ```sh
   cd macos
   swift build
   swift test
   ./scripts/bundle.sh          # build/Tera Term Mac.app ができます
   open "build/Tera Term Mac.app"
   ```
3. ブランチを作って直し、Pull Request を送ってください

詳しい作りは [macos/README.md](macos/README.md) を見てください。
OS によって違う動きは、Windows ではなく macOS のやり方に合わせる方針です。
送っていただいたコードは MIT License で公開します。

---

本家 Tera Term の CONTRIBUTING は [CONTRIBUTING.teraterm.md](CONTRIBUTING.teraterm.md) にあります。
