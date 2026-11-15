# 0009: GitHub App 連携による Pull Request レビューと Issue 連携

- Status: Accepted
- Date: 2026-11-15

## Context

Phase 5 として、GitHub Pull Request に対するコードレビュー依頼（`pull_request.review_requested`）や Issue コメントに自動反応し、Quest を起票して隔離 Docker コンテナ（Mock Agent）を実行、結果を GitHub PR / Issue に投稿する機能を導入する必要があった。

## Decision

1. **GitHub App 認証方式**:
   - マシンユーザー用のアカウントではなく、公式の GitHub App を採用する。
   - 外部 gem（`jwt` や `octokit` 等）を追加せず、Ruby 標準の `openssl` で RS256 JWT を生成し、GitHub REST API から Installation Access Token（有効期限 1 時間の短寿命トークン）を取得する軽量クライアント（`Omochi::GitHub::AppClient`）を実装する。
2. **Webhook 受信と HMAC-SHA256 署名検証**:
   - `POST /webhooks/github` エンドポイントを新設。
   - `X-Hub-Signature-256` ヘッダーを用いて HMAC-SHA256 署名を厳格に検証し、不正署名は 401 Unauthorized で即時拒否する。
   - `X-GitHub-Delivery`（UUID）を `source_event_id` として永続化し、重複配信を安全に除外する。
3. **PR レビュー依頼の対象判定**:
   - `pull_request` イベントの `action: "review_requested"` において、`requested_reviewer.login` が `omochi`（または設定された App スラッグ）と一致する場合に反応する。
   - PR コメント（`issue_comment`）または PR 作成本文において、`@omochi-agent` や `@omochi` メンションに加えて、スラッシュコマンド `/review` または `/omochi` が含まれる場合にも自動で新規 Quest を起票（または既存 Quest に指示を追加）する。
   - 同一 PR への新しいコミット push（`action: "synchronize"`）時は、すでに Quest が存在する場合にのみ再レビュー指示をキューイングする。
4. **結果の反映**:
   - `QuestExecution` の完了時、`ExternalResource` が GitHub PR の場合は GitHub 公式の Pull Request Review API（`POST /repos/{owner}/{repo}/pulls/{number}/reviews`、`event: "COMMENT"`）を用いてレビューサマリを投稿する。Issue の場合は Issue Comment API で投稿する。
   - API 一時障害時は `GitHubNotificationJob` で非同期リトライし、通知の成否によって `QuestExecution` 本体の実行結果を左右しない。
5. **Nginx 構成**:
   - Web サーバー全体を Basic 認証で保護しつつ、`/webhooks/github` パスのみ `auth_basic off;` で認証を除外し、Rails 側の HMAC-SHA256 署名検証によってアクセス制御を行う。

## Consequences

- ユーザーが PR の Reviewers に `omochi[bot]` をアサインするだけで、自動で Quest が起票されて隔離コンテナ内でレビューが行われ、PR に結果が返信される体験が実現する。
- 依存 gem を増やさず、GitHub App の短寿命トークンと HMAC 署名検証により最小権限と高セキュリティを維持できる。
