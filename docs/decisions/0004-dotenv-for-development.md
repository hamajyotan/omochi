# 0004: 開発・テスト環境での dotenv の利用とローカルバインド前提

- Status: Accepted
- Date: 2026-11-14

## Context

ローカル開発時の環境変数管理と、初期 Dashboard の公開範囲を決める必要があった。

## Decision

- `dotenv` gem を `development` / `test` グループのみに導入し、`.env`（Git 管理外）を自動読み込みする。設定項目の説明は `.env.example` に記載し、アプリケーションからは `config/omochi.yml` と `Omochi::Settings` を通じて参照する。
- Phase 1 では Dashboard の認証機能を実装せず、`Procfile.dev` および `bin/dev` では Web サーバーを `127.0.0.1` にバインドする。認証方式は Phase 4 以降で決定する。

## Consequences

- 秘密情報をリポジトリに含めずにローカルで `.env` を使った動作確認ができる。
- 必須設定（Slack Token 等）はそれを利用するコンポーネントからのみ `Omochi::Settings.fetch!` で要求するため、Slack 未設定でも Dashboard とドメイン機能の起動・テストが可能。
