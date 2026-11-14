# 0002: Quest / Instruction / Execution の暫定ステータスと再開規則

- Status: Accepted
- Date: 2026-11-14

## Context

Phase 1 で Quest のキューイングと直列実行を実装するにあたり、Quest、QuestInstruction、QuestExecution の独立したステータス一覧と、完了・失敗後の再開時の状態遷移を定める必要があった。

## Decision

初期実装のステータスと基本遷移を次のとおりとする。

- `Quest.status`: `pending` / `running` / `completed` / `failed` / `cancelled`
- `QuestInstruction.status`: `queued` / `processing` / `processed` / `failed` / `cancelled`
- `QuestExecution.status`: `queued` / `preparing` / `running` / `succeeded` / `failed` / `cancelled`
- `completed` または `failed` の Quest が新しい有効な Instruction を受け付けた場合、同じ Quest（同じ `public_id`）のまま `status` を `pending` に戻し、新しい `QuestExecution` で処理する。過去の Instruction / Execution は上書きしない。
- `cancelled` の Quest への追加指示は現時点では拒否し、手動再開・キャンセル操作の UI 設計時（Phase 4）に再検討する。
- 1 つの Quest につき active（`queued` / `preparing` / `running`）な `QuestExecution` は最大 1 つとし、SQLite の partial unique index でも強制する。

## Consequences

- Quest と Execution のライフサイクルが分離され、Execution の履歴を保持したまま同じ Quest を再開できる。
- DB 制約と短い IMMEDIATE トランザクションによる claim により、複数 Worker や重複 Job が走っても二重実行が起きない。
