# CI/CDと配布

## 現在の自動処理

`.github/workflows/ci.yml` が以下を実行します。

| トリガー | 検証・ビルド | 配布 |
| --- | --- | --- |
| Pull Request | 共通テスト、MacのGPUテスト、Releaseビルド、Mac・iPhone・iPadの起動 | ActionsのArtifactsにプレビューZIPと画面を保存。Releaseは作らない |
| `main`へのpush | 同じ検証 | 両OSのジョブが成功した場合にGitHubのPrereleaseへ自動公開 |
| Actionsから手動実行 | 選んだブランチを検証 | `main`を選び、かつ最新のコミットの場合に公開 |

実行先はmacOS 15 / Ubuntu 24.04、配布物はRelease構成です。MacアプリとiOSシミュレーターアプリはいずれもarm64・x86_64を含みます。バージョンはXcodeプロジェクトの `MARKETING_VERSION`、ビルド番号はGitHub Actionsの `run_number` です。

新しいpushが来ると、同じブランチの古い実行をキャンセルします。配布前にも現在の `main` とビルド元のコミットを比較し、古い結果を新規公開しないようにします。再実行時は同じReleaseを再利用し、完成済みの配布は変更しません。

Releaseのタグは `preview-<run_id>` です。公開前に元のコミット、実行ID、ZIPのSHA-256、両端末の画面を検証します。すべてのファイルをDraftにアップロードした後で公開するため、途中の配布を完成版として表示しません。失敗して残ったDraftは次の再実行で利用できます。

ビルドジョブの権限は `contents: read`、配布ジョブだけ `contents: write` です。GitHub標準の `GITHUB_TOKEN` を使い、追加のアクセストークンは不要です。外部ActionはコミットSHAで固定しています。ActionsのプレビューArtifactsは30日、GitHub Releasesのファイルは削除するまで保持されます。配布数が増えた際の整理は手動です。

## 結果を確認する

- [GitHub Releases](https://github.com/dendencat/sumi-paint/releases): 試すアプリ・画面・チェックサム。
- [GitHub Actions](https://github.com/dendencat/sumi-paint/actions/workflows/ci.yml): 各変更のテスト・配布結果。配布ジョブのSummaryにもURLを表示。
- [インストール手順](preview-install.md): Mac、iPhone・iPadシミュレーターでの確認方法。

手動で作り直すには、Actions → `Build, test, and preview` → `Run workflow` → `main` を選びます。同じ実行の再試行は `Re-run jobs` を使います。

## Apple Developer登録後の移行

現在はApple Developer Programへの未登録を前提とし、TestFlightや公証を実行するジョブはありません。実機配布を始める際は、次を準備します。

1. Apple Developer Programに登録し、iOSのApp IDを作成。App Store Connectにアプリを作り、Bundle Identifierを一致させる。
2. 配布用証明書・秘密鍵、App Store用Provisioning Profile、App Store Connect API Keyを作成する。鍵はGitHubのEnvironment Secretsへ登録し、ソースやReleaseには含めない。
3. アプリアイコンとApp Store提出用のメタデータ・輸出コンプライアンス情報を用意する。
4. 検証済みコミットをiOS実機向けにarchiveし、署名・exportしたIPAをAPI Keyでアップロードするジョブを追加する。実行中だけ一時Keychainに署名情報を読み込み、終了時に削除する。
5. App Store Connectの内部テスターを設定し、TestFlightで試す。外部テスターへの配布はAppleのBeta App Reviewが必要になる場合がある。

API Keyは `ASC_KEY_ID`・`ASC_ISSUER_ID`・`ASC_PRIVATE_KEY`、署名用情報は `APPLE_TEAM_ID`・`IOS_DISTRIBUTION_P12_BASE64`・`IOS_DISTRIBUTION_P12_PASSWORD`・`IOS_PROFILE_BASE64` といったEnvironment Secretsとして管理する想定です。現在はこれらの値を設定する必要はありません。

Macの現在のReleaseプレビューもApp SandboxとHardened Runtimeを有効にしてアドホック署名します。登録後はDeveloper ID Application証明書と公証用の認証を追加し、`notarytool`で公証、`stapler`で結果を添付してから配布する形へ移行します。これにより初回起動時の手動許可を減らせます。
