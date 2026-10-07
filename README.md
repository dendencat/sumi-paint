# Sumi Paint

Mac・iPad・iPhone向けの独自のお絵かきアプリ。調整できるブラシと手ぶれ補正、レイヤー、作品の保存を備えた最初の実装です。

SwiftUIとMetalを使用し、アプリに組み込む外部パッケージはありません。

[![Build, test, and preview](https://github.com/dendencat/sumi-paint/actions/workflows/ci.yml/badge.svg)](https://github.com/dendencat/sumi-paint/actions/workflows/ci.yml)

## プレビューを試す

[`main`の検証済みプレビューをダウンロード](https://github.com/dendencat/sumi-paint/releases)。変更ごとにMac用アプリ、iPhone・iPadシミュレーター用アプリ、起動時の画面を自動公開します。

[インストール手順](docs/preview-install.md)と[CI/CDの構成](docs/ci-cd.md)を参照してください。Mac版はアドホック署名で公証前です。iOS版の配布物はシミュレーター専用で、実機へのTestFlight配布はApple Developer登録後に追加します。

## 機能

- ペン・鉛筆・消しゴム、サイズ、不透明度、硬さ、筆圧カーブ、手ぶれ補正。
- 対応機器の筆圧、iOSのまとまった入力サンプル、Macのペンタブ入力。
- Macのペンボタンの割り当て、一時的なツール切り替え、対応ペンの消しゴム側の自動切り替え。
- キャンバスの拡大・移動・回転、左右反転表示。
- レイヤーの追加・削除・複製・並べ替え・表示・ロック・不透明度。
- 通常・乗算・スクリーン、透明度保護、クリッピング。
- 矩形・投げ縄選択、選択範囲の移動・拡大縮小・回転、画素の消去。
- 現在のレイヤーを参照する塗りつぶし、スポイト、最近使った色。
- 描画・レイヤー編集・変形などのUndo / Redo。
- `.sumipaint` 形式で保存・再編集、PNG / JPEG / HEIC読み込み、透過PNG書き出し。
- 連続描画中にも行う自動復旧用保存。復旧ファイルの一覧から作品を選択・削除できる。

初期版の上限は2048×2048ピクセル・8レイヤー、画像データ128 MiB、Undo履歴64 MiBです。色仕様はsRGBの8bit RGBAです。

## ビルド

必要な環境: Mac、Xcode 16以降、macOS 14以降。iOS / iPadOSの下限は17です。

1. `SumiPaint.xcodeproj` をXcodeで開く。
2. Macは `SumiPaint-macOS`、iPhone・iPadは `SumiPaint-iOS` のSchemeを選ぶ。
3. 実行先を選んでRunする。実機で動かす場合はSigningのTeamと、自分のBundle Identifierを設定する。

生成済みのXcodeプロジェクトを含んでいるため、追加のパッケージ管理ツールは不要です。ソースファイルを追加・削除した場合は、Python 3で再生成してください。

```sh
python3 scripts/generate_project.py
```

## 使い方

Macでは左にブラシと色、右にレイヤーを表示します。iPhoneでは下のツール列で道具を選び、ブラシ・色・レイヤーのボタンから設定を開きます。幅の広いiPadでは設定をサイドパネルに表示します。

- Mac: `B` ペン、`P` 鉛筆、`E` 消しゴム、`G` 塗りつぶし、`I` スポイト、`H` 移動。
- Mac: `Space`を押してドラッグするとキャンバス移動。`Option`クリックで色を取得。`Command`＋スクロールで拡大・縮小。
- Mac: `Command-Z`で戻す、`Command-Shift-Z`でやり直す。`[` / `]`でブラシサイズを変更。
- Mac: `X`で描画ツール・消しゴムを切り替え。`Option`を押している間スポイト。右上メニューの「ペンタブのボタン設定」で右・中クリックの動作を設定。
- iPhone: 1本指で描画、2本指で移動・拡大・回転。2本指タップで戻す。
- iPad: 対応するペンで描画し、指でキャンバスを操作。メニューの「指で描く」も選択可能。

iPhoneはApple Pencilに対応していません。ペンやペンタブの筆圧は、入力機器が値を提供する場合に使用します。筆圧のない入力では一定の太さを基本にし、描き始めを細くする設定を選べます。

WacomドライバからmacOS標準の入力を受け取ります。ドライバのアプリ別設定と実機確認の項目は[Wacomの設定手順](docs/wacom.md)を参照してください。Wacom実機・ドライバでの互換性検証は未実施です。

メニューの「作品を保存」は再編集できる作品ファイルを書き出します。「PNGを書き出す」はレイヤーを合成した画像を書き出します。画面上の白い紙とチェック柄は表示用で、PNGの透明部分は保持されます。

自動保存は復旧用です。作品の持ち出し・保管には「作品を保存」を使ってください。MacとiOSの「ファイル」、AirDropなどで同じ作品ファイルを受け渡せます。

## 検証

共通の描画処理はLinux・Macでテストできます。

```sh
swift test
python3 scripts/check_repository.py
python3 -m unittest discover -s Tests/AutomationTests
```

GitHub Actionsでは、共通処理のテスト、macOSアプリのビルドとMetal描画の統合テスト、iOSアプリのビルド、iPhone・iPadシミュレーターの起動を行います。シミュレーター画像はActionsの成果物に保存します。必要なMetalデバイスがなければ、統合テストは失敗として扱います。

Release構成のMac配布ZIPも展開して起動します。`main`の両OSジョブが成功した場合に、GitHub Releasesへプレビューを自動公開します。

筆圧、遅延、手ぶれ補正の感触、長時間のメモリ使用量は、実機と入力機器での確認が必要です。[実装状況と確認項目](docs/implementation.md)を参照してください。

本番運用・セキュリティレビューの修正と残課題は[対応レポート](docs/review-remediation.md)に記載しています。実機の受け入れ確認と正式配布の準備は継続中です。

## 構成

| パス | 内容 |
| --- | --- |
| `Sources/DrawingCore` | ストローク、座標変換、作品形式、選択・塗りつぶし・変形 |
| `App/PaintEngine.swift` | Metalによるブラシ描画・合成、レイヤー、変更領域のUndo |
| `App/PaintShaders.metal` | ブラシと合成・表示のGPU処理 |
| `App/CanvasInput.swift` | UIKit / AppKitの入力とジェスチャー |
| `App/EditorModel.swift` | 保存・読み込み、復旧ファイル |
| `App/EditorRoot.swift`, `App/Panels.swift` | 端末に合わせた操作画面 |
| `Tests`, `AppTests` | 共通処理とネイティブ描画のテスト |

## ライセンス

[MIT License](LICENSE.md)。採用理由、使用フレームワーク、開発・CIツールは[使用パッケージとライセンス](THIRD_PARTY_NOTICES.md)に記載しています。
