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

## 4. Slack のイベントと Quest の関連付け

- Thread 内のどの種類のメッセージを追加指示として扱うか。
- Quest ID を含む返信をどのように発見・解釈するか。
- bot 自身の投稿、編集、削除、ファイル添付などをどう扱うか。
- Thread 以外の DM / channel message を対象にするか。
- Slack Event の ACK と DB 永続化の順序。

## 5. Docker 実行環境

- Container を Quest 単位で再利用するか、Execution ごとに作成するか。
- workspace の永続化と cleanup の単位。
- Container の network access をどこまで許可するか。
- CPU / memory / process / timeout の初期上限。
- Container 内のユーザー、filesystem、capability の設定。

## 6. プロセス構成と SQLite（一部決定 → [ADR 0003](decisions/0003-solid-queue-separate-database.md)）

- Solid Queue 用 DB をアプリケーション DB から分離し、`ReconcileQuestsJob` で enqueue 漏れを補完する方針は ADR 0003 で決定済み。
- SQLite の WAL mode、`timeout: 5000`、IMMEDIATE トランザクションは設定済み。
- 未決：
  - `omochi-socket` プロセスの起動・監視方法（Phase 3）。
  - バックアップ方針。

## 7. Agent SDK / Agent Session

- Claude / Codex / その他のどの SDK / CLI を採用するか。
- Session の永続化・再開・破棄をどう扱うか。
- Agent event の標準化方法。
- 外部サービス操作を broker / MCP のどちらで提供するか。

## 8. GitHub 連携

- GitHub App / fine-grained PAT 等の認証方式。
- Webhook の対象イベント。
- Issue / PR Description marker の形式と更新規則。
- 単一 repository の設定方法。
- GitHub への進捗・結果の反映方法。

## 9. 運用・UI（一部決定 → [ADR 0004](decisions/0004-dotenv-for-development.md)）

- Phase 1 では Dashboard 認証を設けず `127.0.0.1` バインド前提とすることは ADR 0004 で決定済み。
- 未決：
  - Dashboard の認証方式（Phase 4 以降）。
  - ログの保存期間と表示・検索方法。
  - Slack への進捗通知の頻度・粒度。
  - Quest の手動再開・キャンセルの UI。
  - バックアップ・復旧手順。

## 決定事項の記録

重要な設計判断を確定したら `docs/decisions/` に ADR を追加し、このファイルの該当項目を更新してください。
