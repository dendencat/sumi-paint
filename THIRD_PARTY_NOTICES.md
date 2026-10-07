# 使用パッケージとライセンス

## アプリに組み込む外部パッケージ

**0件**。`Package.swift` の `dependencies` は空です。外部の描画ライブラリ、画像素材、フォント、他製品のコードは同梱していません。

描画・ストローク処理・ファイル形式・画面・プロジェクト生成スクリプトは、このプロジェクトで作成したコードです。本リポジトリのコードと文書は [MIT License](LICENSE.md) で提供します。

## 使用するApple標準フレームワーク

| フレームワーク | 用途 | 提供・ライセンスの扱い |
| --- | --- | --- |
| SwiftUI / Combine | 画面、編集状態の通知 | Apple SDK・OSが提供。AppleのSDK使用条件に従う |
| UIKit | iPhone・iPadのタッチ、ペン、ジェスチャー入力 | 同上 |
| AppKit | Macのマウス、ペンタブ、キーボード入力 | 同上 |
| Metal / MetalKit | ブラシ描画、レイヤー合成、キャンバス表示 | 同上 |
| Foundation | データモデル、保存、読み込み | AppleプラットフォームではOS・SDKが提供 |
| CoreGraphics / ImageIO | 画像の読み込み、PNG書き出し、色の変換 | Apple SDK・OSが提供 |
| UniformTypeIdentifiers | 作品形式、ファイル選択 | 同上 |
| XCTest | テスト専用 | Appleの開発ツールが提供。アプリ本体には含めない |

これらのSDKやOSのフレームワーク自体をリポジトリへコピーしていません。本プロジェクトのMITライセンスは、AppleのSDKや標準フレームワークを再ライセンスするものではありません。

## 開発・検証ツール

| ツール | 用途 | ライセンス・出典 |
| --- | --- | --- |
| Swift / Swift Package Manager | コンパイル、共通処理のテスト | Apache License 2.0。SwiftにはRuntime Library Exceptionがある。[Swiftのライセンス](https://github.com/swiftlang/swift/blob/main/LICENSE.txt) |
| Xcode / Apple SDK | macOS・iOSのビルド、シミュレーター | Appleの開発ツール・SDK使用条件。ツール本体を同梱しない |
| Python 3 標準ライブラリ | Xcodeプロジェクト生成、構成確認、シミュレーター起動 | PSF License。[Pythonのライセンス](https://docs.python.org/3/license.html)。外部Pythonパッケージ不要 |
| PyYAML | 作業環境でのワークフロー構文確認のみ | [MIT](https://github.com/yaml/pyyaml/blob/main/LICENSE)。アプリ・CI・配布スクリプトには不要 |
| Git / GitHub CLI | バージョン管理、公開 | Git: GPL-2.0、GitHub CLI: MIT。開発時に使用し、アプリに同梱しない |

## GitHub Actionsで使用する外部Action

| Action | 固定リビジョン | ライセンス |
| --- | --- | --- |
| actions/checkout v4.2.2 | `11bd71901bbe5b1630ceea73d27597364c9af683` | [MIT](https://github.com/actions/checkout/blob/11bd71901bbe5b1630ceea73d27597364c9af683/LICENSE) |
| actions/upload-artifact v4.6.2 | `ea165f8d65b6e75b540449e92b4886f43607fa02` | [MIT](https://github.com/actions/upload-artifact/blob/ea165f8d65b6e75b540449e92b4886f43607fa02/LICENSE) |
| actions/download-artifact v4.3.0 | `d3f86a106a0bac45b974a628896c90dbdf5c8093` | [MIT](https://github.com/actions/download-artifact/blob/d3f86a106a0bac45b974a628896c90dbdf5c8093/LICENSE) |

これらはCIの実行時に使用し、アプリ本体に含めません。

## MITを採用する理由

外部パッケージのライセンスによる制約がなく、個人・商用を含む利用、改変、再配布を許可する方針に合うため、MITを採用しています。再配布時には著作権表示とライセンス文を保持してください。

利用者が描いた作品に、本ソフトウェアのMITライセンスが自動的に適用されることはありません。

依存パッケージ、外部素材、コピーしたコードを追加する場合は、この一覧と必要なライセンス文を更新してください。
