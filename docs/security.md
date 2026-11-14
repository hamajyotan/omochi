# セキュリティ方針

## 1. 基本原則

Agent は任意のコードやコマンドを実行する可能性があるものとして扱います。Agent Container を信頼境界の外側に置き、omochi のホストプロセスや認証情報へのアクセスを制限します。

## 2. Container の分離

- Agent はホスト上で直接実行しない。
- Quest の作業は Docker Container 内で実行する。
- Agent Container に Docker Socket を mount しない。
- Agent Container からホストの任意ファイルへアクセスできないようにする。
- 必要な workspace のみを明示的に mount する。
- Container の CPU / memory / process / execution time 等の制限を設ける。
- Container の終了後に不要な Container、volume、workspace を cleanup する。
- cleanup が失敗した場合に検出・再試行できるようにする。

Container の具体的な user、capability、network、read-only filesystem、seccomp 等の設定は実装前に検証し、可能な限り権限を絞ります。

## 3. 認証情報

以下の credential を Agent Container に直接渡してはいけません。

- Slack Token
- GitHub Token / App private key
- omochi の DB 接続情報
- その他ホスト側サービスの秘密情報

Agent に外部サービスへの操作権限が必要になった場合は、ホスト側 broker や MCP 等を介して、操作単位で最小権限を与える方式を検討します。MVP では実 Agent に credential を与えません。

## 4. Docker Engine へのアクセス

Docker Engine の操作権限は強い権限を持ちます。Docker Socket を Agent Container に渡してはいけません。

Docker Engine を操作する責務は omochi-worker 側に限定します。Socket の公開範囲や worker の実行ユーザーはデプロイ構成に合わせて検討します。

## 5. Webhook / 外部イベント

- Slack / GitHub の署名や送信元を検証する。
- 外部入力を信頼せず、長さ・形式・許可されたイベント種別を検証する。
- 外部 ID や Quest ID を認可トークンとして扱わない。
- 重複イベントを安全に処理する。
- ログに Token、秘密情報、不要な個人情報を出さない。

## 6. 設定と秘密情報

- `.env` は Git 管理対象外とする。
- `.env.example` に秘密値を記載しない。
- 本番環境では環境に適した Secret 管理方式を使う。
- ログや Dashboard に credential を表示しない。

## 7. MVP の運用上の前提

初期 MVP は単一 Linux ホスト上での運用を想定します。複数ホストでの分散実行、マルチテナント、HA は対象外です。ただし、単一ホストであっても Container の分離と credential の保護は省略しません。
