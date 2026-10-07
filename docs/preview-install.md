# プレビュー版を試す

## ダウンロード

[GitHub Releases](https://github.com/dendencat/sumi-paint/releases)の新しい `Preview` を開きます。`main`への変更がテストを通過するたびに、アプリと画面を自動公開します。各プレビューにはコミットとビルド番号が表示されます。失敗したビルドは公開しません。

Apple Developer Programへの登録前でも、Macで試せる構成です。iPhone・iPad実機での配布は、登録後のTestFlight対応で追加します。

## Macで使う

1. `SumiPaint-macOS-Preview.zip` をダウンロードして展開します。
2. 展開したフォルダの `Sumi Paint.app` を「アプリケーション」フォルダへ移動します。
3. アプリを開きます。対応OSはmacOS 14以降、Apple Silicon・Intel両対応です。

現在は開発確認用のアドホック署名で、Developer ID署名・Appleの公証はありません。そのため初回起動はGatekeeperで止められる場合があります。このリポジトリから取得したプレビューであることを確認してから、macOSの「システム設定」→「プライバシーとセキュリティ」→「このまま開く」で許可してください。Mac全体のセキュリティ設定を無効にする必要はありません。

## iPhone・iPadシミュレーターで使う

MacとXcodeが必要です。シミュレーター用アプリはiPhone・iPad実機にはインストールできません。

1. `SumiPaint-iOS-simulator-Preview.zip` をダウンロードして展開します。
2. Xcodeの「Open Developer Tool」→「Simulator」でiPhoneまたはiPadを起動します。iOS 17以降のランタイムを選んでください。
3. 展開した `Sumi Paint.app` をSimulatorの画面へドラッグしてインストールします。
4. ホーム画面のアプリを開きます。

ターミナルを使う場合は、展開フォルダで次を実行できます。起動中のシミュレーターを1台にしてください。

```sh
xcrun simctl install booted 'Sumi Paint.app'
xcrun simctl launch booted app.dendencat.sumipaint
```

Apple Silicon・Intel Mac用のシミュレーターアーキテクチャを含みます。シミュレーターでは指・ペンの感触や実際の筆圧は確認できません。`iPhone.png` と `iPad.png` でも起動時の画面を確認できます。

## バージョンとチェックサム

ZIP内の `build-info.json` にアプリのバージョン、ビルド番号、元のコミットがあります。Releaseの `manifest.json` は両アプリと画面の情報をまとめたものです。ダウンロードしたファイルと `SHA256SUMS` を同じフォルダに置くと、次のコマンドで一致を確認できます。

```sh
shasum -a 256 -c SHA256SUMS
```

一覧にあるファイルをすべてダウンロードした場合に、全項目が `OK` になります。
