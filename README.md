# omochi (a.k.a. Omochi Agent System)

`omochi` は、複数のプラットフォームをまたいで一つの仕事（Quest）を継続的に管理し、AI Agent に実行させるアシスタント基盤です。

設計・アーキテクチャ・開発計画の詳細は [`docs/README.md`](docs/README.md) および [`AGENTS.md`](AGENTS.md) を参照してください。

## 必要環境

- Ruby 4.0+
- SQLite 3.8+
- Docker Engine（Agent Container の実行に使用）

## セットアップと起動

```bash
cp .env.example .env
bin/setup --skip-server
```

開発サーバー（`127.0.0.1:3000`）、Solid Queue worker（`bin/jobs`）、Slack Socket Mode クライアント（`bin/socket`）の起動：

```bash
# foreman がある場合は web / jobs / socket を同時起動します
bin/dev

# 別ターミナルで個別に起動する場合
bin/rails server -b 127.0.0.1
bin/jobs
bin/socket
```

> **Note:** `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` が未設定の場合、`bin/socket` は案内を表示して終了します（Slack なしでも Dashboard と Docker Agent Execution は動作します）。Dashboard には認証機能がないため、`127.0.0.1` にバインドしてローカル環境でのみ利用してください。

## テストと静的解析

```bash
bin/rails test
bin/rubocop
bin/brakeman
```
