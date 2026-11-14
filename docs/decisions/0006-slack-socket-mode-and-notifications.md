# 0006: Slack Socket Mode 連携のイベント対象、ACK 順序、返信方針

- Status: Accepted
- Date: 2026-11-14

## Context

Phase 3 で Slack Socket Mode によるイベント受信、Quest への関連付け、ACK 返送の順序、Thread 返信のタイミング、およびプロセス構成を決定する必要があった（`docs/open-questions.md` §4, §6, §9）。

## Decision

1. **対象イベントと Quest の関連付け**:
   - `events_api` の `app_mention` のみを対象とする。`bot_id` / `bot_profile` を持つ投稿および `bot_message` / `message_changed` / `message_deleted` / `message_replied` の subtype は無視する。
   - Thread の識別子は `platform: "slack"`, `resource_type: "thread"`, `scope_key: "<team_id>/<channel>"`, `external_id: "<thread_ts || ts>"` として `ExternalResource` に記録する。
   - まだ `ExternalResource` が存在しない Thread でのメンションは `Quest.start!` で新規 Quest を作成し、同一 Thread での後続メンションは既存 Quest への `receive_instruction!`（完了・失敗後の再開を含む）として扱う。
2. **ACK と DB 永続化の順序**:
   - Socket Mode の `{ "envelope_id": ... }` ACK は、Quest / ExternalResource / QuestInstruction の SQLite への永続化が完了した後にのみ返送する。
   - 永続化前にプロセスが異常終了した場合は Slack の再送によって救済され、永続化後の再送は `QuestInstruction` の `(source_platform, source_event_id)` ユニーク制約（`source_event_id = event_id`）によって重複排除される。
3. **Slack Thread への返信粒度**:
   - 1 Instruction につき最大 3 回、元 Thread へ `SlackNotificationJob` で非同期返信する：①受付時（Quest ID と Instruction 番号）、②Execution 開始時、③Execution 完了（要約）または失敗時。
   - Slack API の一時障害やレートリミット時は Job 単位で有限回リトライし、通知の失敗によって `QuestExecution` 自体の成功・失敗状態を変更しない。
4. **通信実装とプロセス構成**:
   - 追加 gem を導入せず、Web API（`apps.connections.open`, `chat.postMessage`）は `Net::HTTP`、Socket Mode の WebSocket 通信は `OpenSSL::SSL::SSLSocket` + `websocket` gem を用いた `Omochi::Slack::SocketClient` で実装し、テストでは `Omochi::Slack::FakeWebClient` に差し替える。
   - Socket Mode プロセスは `bin/socket` として分離し、`SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` 未設定時は安全にスキップする。

## Consequences

- イベントロストと二重実行の両方を防ぎつつ、Slack API の遅延や障害が Agent Execution や ACK 応答時間を阻害しない。
