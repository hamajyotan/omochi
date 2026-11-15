# 未決事項

このファイルは、現時点で方針が確定していない事項を管理します。実装上の都合だけで暗黙に決定せず、必要なタイミングで選択肢とトレードオフを整理してください。

## 1. Quest ID（決定済み → [ADR 0001](decisions/0001-quest-id-format.md)）

- 内部主キーは整数 `id`、外部公開 ID は `public_id`（`qst_` + UUID v7）として分離済み。

## 2. Quest と Instruction の状態遷移（決定済み → [ADR 0002](decisions/0002-provisional-statuses.md), [ADR 0007](decisions/0007-quest-cancel-reopen-and-retry.md)）

- status 一覧、`completed` / `failed` の自動再開、および `cancelled` への遷移と明示的 `reopen!` は ADR 0002 / ADR 0007 で決定済み。

## 3. Instruction と Execution の対応（決定済み → [ADR 0007](decisions/0007-quest-cancel-reopen-and-retry.md)）

- MVP は 1 Instruction : 1 Execution とし、失敗・キャンセルされた Instruction の再試行（`retry!`）は同一 Instruction を `queued` に戻して新しい `QuestExecution` を作成する方式で決定済み。
- 未決（MVP 後）：
  - 複数 Instruction を一つの Execution にまとめる将来拡張。

## 4. Slack のイベントと Quest の関連付け（決定済み → [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md)）

- `app_mention` の対象化、Thread `ExternalResource` による関連付け、DB 永続化後の ACK 返送、受付・開始・完了/失敗の通知は ADR 0006 で決定済み。

## 5. Docker 実行環境（決定済み → [ADR 0005](decisions/0005-docker-execution-isolation-and-workspace.md)）

- Execution ごとの Container 作成・削除、Quest 単位 workspace、セキュリティ・リソース上限、JSONL イベントプロトコル、heartbeat / cleanup 再試行は ADR 0005 で決定済み。

## 6. プロセス構成と SQLite（決定済み → [ADR 0003](decisions/0003-solid-queue-separate-database.md), [ADR 0005](decisions/0005-docker-execution-isolation-and-workspace.md), [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md)）

- `bin/rails server`（web）、`bin/jobs`（worker）、`bin/socket`（Slack Socket Mode）の 3 プロセス構成と、Solid Queue DB 分離 + `ReconcileQuestsJob` は決定済み。

## 7. Agent SDK / Agent Session（決定済み → Antigravity）

- Agent コアエンジンとして Google Antigravity（Python SDK `google-antigravity`）を採用。
- 隔離された Docker コンテナ内で Antigravity Agent を実行し、ストリーミングイベント（思考プロセス `thoughts`・ツール実行 `tool_calls`）を omochi の JSONL プロトコルに変換してホストへ伝達する。
- 外部サービス認証情報（Slack / GitHub）はコンテナへ渡さず、LLM 推論クレデンシャル（API キー等）のみを最小権限で渡す。

## 8. GitHub 連携（決定済み → [ADR 0009](decisions/0009-github-app-pr-review-and-issue-integration.md)）

- GitHub App 認証（RS256 JWT & Installation Token）、HMAC-SHA256 Webhook 検証、`review_requested` による PR レビュー起動、および PR Review API による結果返信は ADR 0009 で決定済み。
- 未決（将来拡張）：
  - 複数 repository への対応。
  - PR インラインコメント（ファイル・行単位の指摘）のサポート。

## 9. 運用・UI（決定済み → [ADR 0004](decisions/0004-dotenv-for-development.md), [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md), [ADR 0007](decisions/0007-quest-cancel-reopen-and-retry.md), [ADR 0010](decisions/0010-github-oauth-authentication-and-allowlist.md)）

- Dashboard 認証方式は GitHub OAuth + `ALLOWED_GITHUB_USERS` によるホワイトリスト認可で決定（ADR 0010）。
- MVP 後の検討事項：
  - 長期運用時のログ・workspace 保存期間とバックアップ手順。

## 決定事項の記録

重要な設計判断を確定したら `docs/decisions/` に ADR を追加し、このファイルの該当項目を更新してください。
