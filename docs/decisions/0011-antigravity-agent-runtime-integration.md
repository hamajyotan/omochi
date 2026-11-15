# 0011: Google Antigravity Agent ランタイムの統合

- Status: Accepted
- Date: 2026-11-15

## Context

Phase 7 として、これまでのダミー応答（Mock Agent）から、本格的な推論・コード調査・自律改修を行う実 AI コーディングエージェントへの移行が必要となった。
エージェントのコアエンジンとして Google Antigravity（Python SDK `google-antigravity`）を採用し、既存の Docker 隔離アーキテクチャおよび JSONL イベントストリーミングプロトコルに統合する。

## Decision

1. **Docker 隔離とランタイム切り替え**:
   - Agent はホスト上で直接実行せず、Quest 単位で隔離された Docker Container 内で実行する（`AGENTS.md` のセキュリティ境界を厳格に保持）。
   - 環境変数 `OMOCHI_AGENT_RUNTIME`（`"mock"` または `"antigravity"`）によって、テスト時の Mock Agent と実環境の Antigravity Agent をシームレスに切り替えられる設計とする。
2. **アダプタスクリプト（`agent/antigravity_agent.py`）**:
   - コンテナのエントリーポイントとして Python スクリプトを用意し、ホストがマウントした `/workspace/.omochi_instruction.json` から指示を読み取る。
   - `google.antigravity.Agent` の `CapabilitiesConfig` を有効化し、`/workspace` 内のコード閲覧・編集ツールを提供。
   - `response.thoughts`（推論・思考過程）や `response.tool_calls`（ツール実行）を非同期ストリームで受け取り、omochi の標準 JSONL プロトコル（`{"type": "progress", "message": "..."}`）として stdout に即時出力する。
   - 最終出力テキストを `{"type": "result", "summary": "..."}` として出力し、終了する。
3. **セキュリティ境界とネットワーク構成**:
   - Slack Token、GitHub App 秘密鍵、DB 接続情報などのセンシティブな認証情報はコンテナに渡さない。
   - Antigravity の LLM 推論に必要な `GEMINI_API_KEY` のみ、ランタイムが `"antigravity"` の場合にコンテナ環境変数へ安全に注入する。
   - Mock 実行時の `--network none` に対し、Antigravity 実行時は Gemini API へのアウトバウンド通信を許可するため `--network bridge`（環境変数 `OMOCHI_DOCKER_NETWORK`）を適用する。
4. **コンテナイメージ（`docker/agent/Dockerfile`）**:
   - Python 3.12 をベースとし、Git、ビルドツール、`google-antigravity` SDK を組み込んだ軽量イメージを定義。

## Consequences

- 既存の Rails 側（`DockerRunner`、Turbo Streams ダッシュボード、GitHub/Slack 通知基盤）を破壊することなく、リアルタイムな思考過程の可視化と実推論・自律改修が可能になる。
- テスト環境では完全隔離・API キー不要の Mock Agent が動作し、テストスイートの高速性と安全性を維持できる。
