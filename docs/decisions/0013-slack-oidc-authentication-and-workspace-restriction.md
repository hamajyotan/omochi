# 0013: Slack OpenID Connect 認証と特定ワークスペース限定への移行

- Status: Accepted
- Date: 2026-11-18
- Supersedes: [0010: GitHub OAuth 認証とホワイトリスト認可による Dashboard 保護](0010-github-oauth-authentication-and-allowlist.md)

## Context

ADR 0010 では GitHub App の OAuth 機能を用いた Dashboard 認証を導入したが、omochi の中心的な入口は Slack であり、GitHub アカウントに依存しない認証基盤と、特定の Slack ワークスペースメンバーのみに利用を限定する運用が望ましい。

## Decision

1. **認証プロバイダの変更（Sign in with Slack / OpenID Connect）**:
   - Dashboard の認証プロバイダを GitHub OAuth から Slack の OpenID Connect（`https://slack.com/openid/connect/authorize`、`openid.connect.token`、`openid.connect.userInfo`）へ移行する。
   - 既存の Slack App の App Credentials（`SLACK_CLIENT_ID` / `SLACK_CLIENT_SECRET`）を流用し、新規 gem を追加せず Ruby 標準の `Net::HTTP` で `Omochi::Slack::OAuthClient` を実装する。
2. **特定 Slack ワークスペースへの限定（`SLACK_TEAM_ID`）**:
   - 環境変数 `SLACK_TEAM_ID` を導入し、omochi インスタンス全体を特定の 1 ワークスペース専用として運用できるようにする。
   - **Dashboard ログイン時**: `openid.connect.userInfo` で取得した `https://slack.com/team_id` が `SLACK_TEAM_ID` と一致しない場合は `403 Forbidden` とする。
   - **Socket Mode イベント受信時**: `Omochi::Slack::EventHandler` でも `SLACK_TEAM_ID` と一致しないワークスペースからのイベントを無視する。
3. **ユーザー単位ホワイトリストの任意併用（`ALLOWED_SLACK_USERS`）**:
   - ワークスペース内の特定ユーザー（例: ゲスト除外や管理者限定）にさらに絞りたい場合は、環境変数 `ALLOWED_SLACK_USERS`（Slack User ID のカンマ区切り）を併用できる。
4. **GitHub OAuth 設定の廃止**:
   - `GITHUB_CLIENT_ID`、`GITHUB_CLIENT_SECRET`、`ALLOWED_GITHUB_USERS` および `Omochi::GitHub::OAuthClient` を廃止する（GitHub App による PR レビュー・Webhook・Workspace 同期機能は維持する）。

## Consequences

- GitHub アカウントを持たないチームメンバーでも Slack ワークスペースに所属していれば Dashboard にログインできる。
- 認証と Slack イベント処理の双方が同一の `SLACK_TEAM_ID` に基づいて保護される。
- Slack OpenID Connect の Redirect URL は原則 HTTPS が必須となるため、ローカル開発環境でログインフローを検証する場合は HTTPS トンネル（ngrok 等）を利用する。
