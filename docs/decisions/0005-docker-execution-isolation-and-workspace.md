# 0005: Docker 実行環境の分離設定と Quest 単位 Workspace

- Status: Accepted
- Date: 2026-11-14

## Context

Phase 2 で Agent Container のライフサイクル、workspace の保持単位、セキュリティ制限、Docker Engine との連携方式を決定する必要があった（`docs/open-questions.md` §5）。

## Decision

1. **Container の作成単位**: 1 回の `QuestExecution` ごとに新しい Docker Container を作成し、Execution 終了後に強制削除（`docker rm --force --volumes`）する。
2. **Workspace の保持単位**: Quest 単位のホストディレクトリ（`storage/workspaces/<quest_public_id>`）を用意し、Container 内の `/workspace:rw` に bind mount する。同一 Quest の後続 Instruction や再開時に成果物を引き継げるようにし、指示内容は `/workspace/.omochi_instruction.json` として渡す。
3. **Container のセキュリティ・リソース制限**:
   - `--network none`（外部通信遮断）
   - `--read-only`（ルート FS 読み取り専用、`/tmp` のみ `rw,noexec,nosuid,size=64m` の tmpfs）
   - `--cap-drop ALL`、`--security-opt no-new-privileges`、Worker と同一の非 root UID/GID で実行
   - Slack / GitHub 等の秘密情報および Docker Socket は一切渡さない
   - リソース初期上限のデフォルトは `memory=512m`、`cpus=1.0`、`pids-limit=128`、`timeout=120s` とし、`config/omochi.yml`（環境変数）で変更可能にする
4. **Docker 連携方式と Mock Agent イメージ**:
   - 追加 gem を導入せず、`Open3` に配列引数を渡す `Omochi::Docker::CliClient` で `docker` CLI を呼び出す（シェル展開なし）。テストでは `Omochi::Docker::FakeClient` に差し替え可能とする。
   - 初期イメージは `ruby:4.0` をデフォルトとし、ホスト上の `agent/mock_agent.rb` を `/opt/omochi/mock_agent.rb:ro` に read-only mount して実行する。
5. **構造化イベントと異常回復**:
   - Agent は stdout に JSON Lines（`started` / `progress` / `log` / `completed` / `failed`）を出力し、`QuestExecutionEvent` として順次保存する。
   - Execution 実行中は `heartbeat_at` を定期更新し、Worker 異常終了時は `ReconcileQuestsJob` が `worker_lost` として失敗確定・Container cleanup 再試行を行う。

## Consequences

- Execution ごとにクリーンな Container で実行しつつ、Quest 単位のファイル引き継ぎが可能になる。
- Docker Engine の一時障害で `docker rm` が失敗しても、`cleanup_status`（`pending` / `failed` / `completed`）により `ReconcileQuestsJob` で回収できる。
