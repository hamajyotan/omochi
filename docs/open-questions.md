# 未決事項

このファイルは、現時点で方針が確定していない事項を管理します。実装上の都合だけで暗黙に決定せず、必要なタイミングで選択肢とトレードオフを整理してください。

## 1. Quest ID（決定済み → [ADR 0001](decisions/0001-quest-id-format.md)）

- 内部主キーは整数 `id`、外部公開 ID は `public_id`（`qst_` + UUID v7）として分離済み。

## 2. Quest と Instruction の状態遷移（一部決定 → [ADR 0002](decisions/0002-provisional-statuses.md)）

- 暫定 status 一覧と、`completed` / `failed` の Quest に新しい指示が来たときに `pending` に戻して再開する方針は ADR 0002 で決定済み。
- 未決：
  - `cancelled` の Quest に新しい指示が来たときの扱い。
  - ユーザーによるキャンセルと手動再開の操作方法（Phase 4）。

## 3. Instruction と Execution の対応

- MVP は 1 Instruction : 1 Execution を基本とする。
- 複数 Instruction を一つの Execution にまとめる将来拡張をどの程度考慮するか。
- 失敗した Instruction を再実行する際、同じ Instruction を再試行するか、新しい Instruction を作るか。

## 4. Slack のイベントと Quest の関連付け（決定済み → [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md)）

- `app_mention` の対象化、Thread `ExternalResource` による関連付け、DB 永続化後の ACK 返送、受付・開始・完了/失敗の 3 段階通知は ADR 0006 で決定済み。
- 未決：
  - ファイル添付や Thread 外 DM への将来拡張。

## 5. Docker 実行環境（決定済み → [ADR 0005](decisions/0005-docker-execution-isolation-and-workspace.md)）

- Execution ごとの Container 作成・削除、Quest 単位 workspace、セキュリティ・リソース上限、JSONL イベントプロトコル、heartbeat / cleanup 再試行は ADR 0005 で決定済み。
- 未決：
  - 完了から長期間経過した Quest workspace ディレクトリのアーカイブ・削除ポリシー（運用フェーズで検討）。

## 6. プロセス構成と SQLite（決定済み → [ADR 0003](decisions/0003-solid-queue-separate-database.md), [ADR 0005](decisions/0005-docker-execution-isolation-and-workspace.md), [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md)）

- `bin/rails server`（web）、`bin/jobs`（worker）、`bin/socket`（Slack Socket Mode）の 3 プロセス構成と、Solid Queue DB 分離 + `ReconcileQuestsJob` は決定済み。
- 未決：
  - 本番運用時のバックアップ方針。

## 7. Agent SDK / Agent Session

- Claude / Codex / その他のどの SDK / CLI を採用するか。
- Session の永続化・再開・破棄をどう扱うか。
- Agent event の標準化方法（Mock Agent 用の JSONL は ADR 0005 で定義済み）。
- 外部サービス操作を broker / MCP のどちらで提供するか。

## 8. GitHub 連携

- GitHub App / fine-grained PAT 等の認証方式。
- Webhook の対象イベント。
- Issue / PR Description marker の形式と更新規則。
- 単一 repository の設定方法。
- GitHub への進捗・結果の反映方法。

## 9. 運用・UI（一部決定 → [ADR 0004](decisions/0004-dotenv-for-development.md), [ADR 0006](decisions/0006-slack-socket-mode-and-notifications.md)）

- Phase 1 では Dashboard 認証を設けず `127.0.0.1` バインド前提とすることは ADR 0004 で決定済み。Slack 通知粒度は ADR 0006 で決定済み。
- 未決：
  - Dashboard の認証方式（Phase 4 以降）。
  - ログの保存期間と表示・検索方法。
  - Quest の手動再開・キャンセル・失敗 Instruction 再試行の UI（Phase 4）。
  - バックアップ・復旧手順。

## 決定事項の記録

重要な設計判断を確定したら `docs/decisions/` に ADR を追加し、このファイルの該当項目を更新してください。
