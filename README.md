# omochi

`omochi` は、複数のプラットフォームをまたいで一つの仕事（Quest）を継続的に管理し、AI Agent に実行させるアシスタント基盤です。

設計・アーキテクチャ・開発計画の詳細は [`docs/README.md`](docs/README.md) および [`AGENTS.md`](AGENTS.md) を参照してください。

## 必要環境

- Ruby 4.0+
- SQLite 3.8+
- Docker Engine（Phase 2 以降で Agent Container の実行に使用）

## セットアップと起動

```bash
cp .env.example .env
bin/setup --skip-server
```

開発サーバー（`127.0.0.1:3000`）と Solid Queue worker の起動：

```bash
# foreman がある場合は web と jobs を同時起動します
bin/dev

# 別ターミナルで個別に起動する場合
bin/rails server -b 127.0.0.1
bin/jobs
```

> **Note:** Phase 1 時点では Dashboard に認証機能がないため、`127.0.0.1` にバインドしてローカル環境でのみ利用してください。また、Phase 1 の Execution runner は Docker を使わないプレースホルダー実装であり、Phase 2 で Docker 上の Mock Agent に置き換えます。

## テストと静的解析

```bash
bin/rails test
bin/rubocop
bin/brakeman
```
