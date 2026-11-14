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

## 7. Agent SDK / Agent Session（Phase 6 で決定）

- Claude / Codex / その他のどの SDK / CLI を採用するか。
- Session の永続化・再開・破棄をどう扱うか。
- 外部サービス操作を broker / MCP のどちらで提供するか。

## 8. GitHub 連携（Phase 5 で決定）

- GitHub App / fine-grained PAT 等の認証方式。
- Webhook の対象イベント。
- Issue / PR Description marker の形式と更新規則。
- 単一 repository の設定方法。
- GitHub への進捗・結果の反映方法。

## 9. 運用・UI（MVP 範囲は決定済み → [ADR 0004](decisions/0004-dotenv-for-development.md), [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md), [ADR 0007](decisions/0007-quest-cancel-reopen-and-retry.md)）

- MVP 後の検討事項：
  - 本番公開時の Dashboard 認証方式。
  - 長期運用時のログ・workspace 保存期間とバックアップ手順。

## 決定事項の記録

重要な設計判断を確定したら `docs/decisions/` に ADR を追加し、このファイルの該当項目を更新してください。
