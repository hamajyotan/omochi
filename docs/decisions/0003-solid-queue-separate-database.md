# 0003: Solid Queue 用 SQLite DB の分離と Reconcile Job

- Status: Accepted
- Date: 2026-11-14

## Context

SQLite と Solid Queue を使う構成では、Solid Queue のテーブルをアプリケーション DB（`primary`）と同居させるか、Rails 8 標準どおり別 SQLite ファイル（`queue`）に分離するかを選択する必要がある。

## Decision

- development / production ともに、アプリケーション DB（`primary`）と Solid Queue 用 DB（`queue`）、Action Cable 用 DB（`cable`）を別 SQLite ファイルに分離する。
- DB が分かれるため、Instruction の永続化と `QuestProcessingJob` の enqueue は単一トランザクションにできない。Instruction を先にコミットした後に Job を enqueue する。
- enqueue 前にプロセスが異常終了した場合などの取りこぼしを回復するため、`queued` の Instruction を持ちかつ active な Execution を持たない Quest を再スケジュールする `ReconcileQuestsJob` を Solid Queue の recurring task として定期実行する。

## Consequences

- Solid Queue のポーリング書き込みとアプリケーションのトランザクションが別ファイルになり、SQLite の書き込みロック競合を抑えられる。
- Job の重複実行が起こり得るが、`Quest#claim_next_instruction!` が冪等かつ排他的であるため二重実行にはならない。
