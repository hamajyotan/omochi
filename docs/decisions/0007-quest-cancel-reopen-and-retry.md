# 0007: Quest のキャンセル・再開、Instruction の再試行、Turbo Streams 更新

- Status: Accepted
- Date: 2026-11-14

## Context

Phase 4 で Dashboard を完成させるにあたり、Quest のキャンセルと `cancelled` 状態からの再開方法、失敗・キャンセルされた Instruction の再試行方法、およびブラウザへのリアルタイム反映方式を決定する必要があった（`docs/open-questions.md` §2, §3, §9）。

## Decision

1. **Quest のキャンセル（`Quest#cancel!`）**:
   - active な `QuestExecution` が存在する場合は `cancelled`（`error_kind: "cancelled_by_user"`）に遷移させ、稼働中の Docker Container を即座に停止・削除（`docker kill` + `docker rm -f`）する。
   - 未処理（`queued` / `processing`）の `QuestInstruction` もすべて `cancelled` に遷移させ、Quest の `status` を `cancelled` にする。
2. **`cancelled` 状態からの再開（`Quest#reopen!`）**:
   - 意図的にキャンセルされた Quest が Slack スレッド上の会話等で誤って自動再稼働するのを防ぐため、`cancelled` の Quest は外部イベント単体では自動再開しない。
   - Dashboard 上の明示的な「Reopen Quest」操作（`Quest#reopen!`）または失敗・キャンセルされた Instruction の「Retry」操作によって `pending` に戻して再開する。
3. **Instruction の再試行（`QuestInstruction#retry!`）**:
   - `failed` または `cancelled` の `QuestInstruction` を再試行するときは、新しい重複 `QuestInstruction` レコードを作るのではなく、同じ `QuestInstruction` を `queued` に戻し、新しい `QuestExecution` を作成して処理する。これにより過去の失敗 Execution と再試行 Execution の両方の履歴が保持される。
4. **Turbo Streams による Dashboard 更新**:
   - Quest 一覧画面は `:quests` ストリーム、Quest 詳細画面は `@quest` ストリームを購読し、Instruction 受付・Execution 状態遷移・ExecutionEvent 受信・キャンセル/再開時に `Turbo::StreamsChannel.broadcast_replace_to` で対象 DOM を自動更新する。

## Consequences

- すべての過去 Execution 履歴を失わずに Dashboard からキャンセル・再開・再試行を安全に行える。
- Worker プロセスからの状態更新が Solid Cable 経由でブラウザに即時反映される。
