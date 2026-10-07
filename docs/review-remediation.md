# 本番運用・セキュリティレビューへの対応

レビュー日・対応日: 2026-10-07。対象の元コミットは `34713b343d5aaa349391a691dd258a21256ed95a`。

即時に対応できる不具合を修正し、条件が必要な項目はIssueに登録しました。本番向けの受け入れ確認は継続中です。実機性能、入力機器、終了境界、正式配布が未確認のため、現在の配布は検証用プレビューとして扱います。

## 指摘と修正

| 指摘 | 対応 | 残る条件 |
| --- | --- | --- |
| SP-SEC-001: 作品デコード前の参照増幅によるメモリ・CPU消費 | 共通の `DocumentSnapshot.decode` で、モデルを構築する前にProperty Listの構造とデータ量を検証。実読込バイト数も制限 | Darwinの隔離・メモリ制限下の測定は [#1](https://github.com/dendencat/sumi-paint/issues/1) |
| R1: 連続編集で自動保存が先送りされる | 変更ごとのタイマー再作成を廃止。最後の変更から2秒、最初の未保存変更から最大10秒を目安に開始。描画途中の画素も保存。書込みは単一タスクにまとめる | CPU処理中・書込み中は実時間が伸びる。ウィンドウ閉鎖、OSの期限、容量不足は [#3](https://github.com/dendencat/sumi-paint/issues/3) |
| R2: 表示操作で描画中の線が失われ、Undoが前の線まで消す | UIKitのジェスチャー開始・タッチ中断では描画を確定。2本指Undoは進行中の線を履歴に入れてから1回戻す | 実際のジェスチャー認識順と入力機器は [#2](https://github.com/dendencat/sumi-paint/issues/2) |
| R3: 復元失敗でもUndo/Redo履歴を消費する | 画素復元が成功した場合だけ履歴を移動。メモリ確保失敗時は履歴・変更番号を保持。キャンセルの復元失敗では元画素を保持し、再試行を用意 | GPU自体が失敗した場合は再起動が必要。部分実行後の自動再開は [#3](https://github.com/dendencat/sumi-paint/issues/3) |
| R4: GPU実行失敗でも保存・出力を成功扱いにする | 実際のコマンドの完了状態とエラーを検査。失敗を保持し、スナップショット・PNG出力・編集を拒否。最後の正常な復旧ファイルを上書きしない | 実機のGPU障害・再起動復旧は [#3](https://github.com/dendencat/sumi-paint/issues/3) |
| R5: 古い復旧版を選べず、空キャンバスが最新候補になる | 全候補を日時・容量付きで一覧化し、選択・手動削除を追加。未編集の空キャンバスは保存しない。削除済みの現在の復旧版は次回保存で再作成可能 | 自動保持数・総容量・未保存作品の保護方針は [#3](https://github.com/dendencat/sumi-paint/issues/3) |
| Mac配布のHardened Runtimeが無効 | Release構成とCIのアドホック署名で有効化。App Sandboxを維持 | Developer ID・公証はApple登録後、[#4](https://github.com/dendencat/sumi-paint/issues/4) |
| MetalのないCIでも統合テストが成功扱いになる | 必須のMetalテストデバイスがなければ失敗に変更 | 実機テストを置き換えるものではない |

Macのアプリ終了は保存完了を待ち、失敗時には終了の中止か明示的な破棄を選べます。iOSではバックグラウンド保存の実行猶予を要求します。強制終了やOSによる終了の直前の編集を完全に保全することはできません。

## セキュリティ修正の境界

元の経路は、ファイル選択・復旧ファイル → `DocumentSnapshot.decode` → `PropertyListDecoder` → 構築済みの全レイヤーを検証、でした。攻撃者が作成した小さなバイナリProperty Listに多数の同一参照を入れると、上限チェック前に画素やレイヤーが展開されます。CWE-400 / CWE-770に該当する可用性の問題です。

修正では、バイナリを画素のコピーなしに調べ、XMLはストリームで検査します。オブジェクト数512、参照を辿る回数4096、深さ16、辞書32組、配列8要素、文字列64 KiB、参照を考慮したメタデータ合計256 KiBを上限にします。幅・高さ・レイヤー数と各画素データの正確な長さを確認し、循環・重複キー・外部エンティティを拒否します。その後で既存のFoundationデコーダーと画素・設定の検証を行います。

未知の拡張フィールドにも同じ予算を適用します。従来受け入れた無制限の拡張配列や極端に長い結合文字列は拒否します。通常のv1ファイル、最大キャンバス・8レイヤー、Unicode名、XMLのCDATA・UTF-16・BOM、先頭空白、バイナリDataのスライスは互換性テストの対象です。256文字の家族絵文字の名前と、最大サイズのXML画素も確認します。

ファイルの事前サイズ情報だけに依存せず、`BoundedFileReader` が実際に読んだサイズを作品160 MiB・画像32 MiB以下に制限します。ファイルが検査後に増える場合にも読込みを打ち切ります。

主要な変更先は `Sources/DrawingCore/PropertyListPreflight.swift`、`Models.swift`、`BoundedFileReader.swift` と `App/EditorModel.swift`。運用の修正は `PaintEngine.swift`、`CanvasInput.swift`、復旧スケジュール・一覧・ライフサイクル処理にあります。外部パッケージは追加していません。

## 検証方法と確認範囲

検証は構文・ビルド、不正入力、正常ファイル・回帰テストの順で行います。

| 検証 | 方法・範囲 |
| --- | --- |
| 共通処理 | `swift test`。不正な繰返し参照、画素長、メタデータ、XML、正常ファイル、復旧期限、一覧・削除・再保存を追加 |
| ネイティブ処理 | CIの `xcodebuild test`。進行中の線のUndo/Redo、確保失敗後の履歴保持・キャンセル再試行、GPU失敗時の出力拒否、連続描画中の保存、最後の正常な復旧版の保全を追加 |
| プロジェクト・配布 | `python3 scripts/check_repository.py`、プロジェクト再生成の一致、`python3 -m unittest discover -s Tests/AutomationTests` |
| Mac配布 | universal Releaseビルド、Sandbox・Hardened Runtimeを含む署名、署名検証、ZIPを再展開して起動 |
| iOS | universalシミュレーター版のReleaseビルド、iPhone・iPadの起動と画面。描画操作の実機検証は含まない |

Linux Swift 6.0.3で、元の入力6種をプロセス隔離して再実行しました。64 MiBのデータ領域制限でも、不正な64レイヤー・25万参照・過大な8枚の画素はすべて例外で拒否され、正常な1枚・8枚の対照入力は受理されました。元の64レイヤー入力は同じ制限でシグナル終了しました。

隔離検証の測定では、64枚の同一1 MiB参照は追加のピークメモリ約1 MiB・約1 msで拒否されました。修正前は約65 MiB増加しました。25万参照もモデル構築前に拒否されました。これはLinuxの隔離検証の値で、実機のメモリ保証ではありません。最終候補でも同じ入力と互換性・回帰テストを再確認しました。測定値は[隔離検証の結果](reviews/security-trigger-results.json)に記録しています。

ローカルでは共通処理27件、配布処理8件、Mac・iOS向けのSwift構文確認、プロジェクト再生成の一致確認が成功しました。UIKit・AppKit・Metalの実行はLinuxでは行えないため、GitHubのMacジョブを必須の検証にしています。

独立した読み取り専用レビューを修正前・修正候補に実施しました。候補レビューで見つかった長い絵文字名と大きいXMLデータの拒否を修正し、回帰テストを追加しています。

[GitHub Actions](https://github.com/dendencat/sumi-paint/actions/workflows/ci.yml)で各コミットの結果を確認できます。[プレビュー一覧](https://github.com/dendencat/sumi-paint/releases)は両OSの必須ジョブが成功した場合だけ更新されます。ネイティブ検証の最終結果は対応コミットのCIと配布物で確認します。

## 条件が必要な項目と対応策

| Issue | 条件 | 対応策・完了条件 |
| --- | --- | --- |
| [#1 メモリ・応答性・最小OS](https://github.com/dendencat/sumi-paint/issues/1) | iPhone/iPad実機、Intel・Apple Silicon Mac、最低対応OS | 最大作品で長時間描画、ピークメモリ・保存時間・遅延を測定。メモリ警告・不正画像・Darwinデコードを隔離検証し、端末別上限を決める |
| [#2 Wacom・Apple Pencil](https://github.com/dendencat/sumi-paint/issues/2) | 対応機器・ドライバ | ボタン、反転ペン、筆圧、フォーカス切り替え、ペンと指の混在を実機で確認し、互換性表を作る |
| [#3 終了・復旧容量・GPU障害](https://github.com/dendencat/sumi-paint/issues/3) | 終了・低容量・GPU障害の検証環境と保持方針 | 個別ウィンドウの終了待機、期限切れ・ENOSPCの注入、再試行、未保存作品を守る容量整理、GPU障害後の復旧を検証する |
| [#4 正式署名・TestFlight](https://github.com/dendencat/sumi-paint/issues/4) | 個人のApple Developer Program登録とAppleの配布資格情報 | TestFlight、Developer ID署名、公証・添付・Gatekeeper検証をCIに追加し、実機へ配布する |

## レビューの利用環境

Codex Securityの `security-scan` / `fix-finding` スキルの利用可能な指示を参照しました。公式のWorkbench・スキャン実行ツールと参照リソースの一部がこの接続に存在しないため、コード経路の確認、隔離した再現実験、修正とテストによるレビューとして記録しています。公式サービスのスキャン完了を示すものではありません。

OpenAI Enterprise契約、組織管理権限、企業向けセキュリティ基盤は要求していません。利用可能な環境だけでレビュー・修正・CIを進めています。一般向けの本番配布は、Apple登録と上記の受け入れ確認が完了してから判断します。
