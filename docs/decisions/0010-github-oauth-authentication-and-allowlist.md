# 0010: GitHub OAuth 認証とホワイトリスト認可による Dashboard 保護

- Status: Accepted
- Date: 2026-11-15

## Context

Phase 6 として、Nginx の HTTP Basic 認証を撤廃し、よりセキュアでユーザーフレンドリーなシングルサインオン（SSO）へ移行する必要があった。
omochi は開発者向け基盤であり、すでに Phase 5 で GitHub App との連携基盤を確立しているため、GitHub OAuth を用いた認証と環境変数による利用者のホワイトリスト制御（`ALLOWED_GITHUB_USERS`）を導入する。

## Decision

1. **認証プロバイダ**:
   - 既存の GitHub App（`omochi-agent`）の OAuth 機能（User authorization）を利用する。新たな OAuth App や外部認証サービスを追加せず、既存の App 設定（Client ID / Client Secret / Redirect URI）を活用する。
2. **依存 gem の最小化**:
   - OmniAuth や Devise などの重厚な認証 gem を追加せず、Ruby 標準の `Net::HTTP`、`URI`、`SecureRandom` を用いた軽量クライアント（`Omochi::GitHub::OAuthClient`）を実装する。
3. **CSRF（State）対策**:
   - 認可リクエスト時に `SecureRandom.hex(16)` で生成した推測不可能な `state` パラメータをセッションに保持し、コールバック受信時に完全一致を検証する。一致しない場合は即座に認証を拒否する。
4. **ホワイトリスト認可**:
   - 認証成功後、取得した GitHub ユーザー名（`login`）を環境変数 `ALLOWED_GITHUB_USERS`（カンマ区切り、大文字小文字無視）と照合する。
   - ホワイトリストに含まれないユーザーには `403 Forbidden` を返却し、ダッシュボードへのアクセスを完全に遮断する。
5. **アクセス制御とセッション管理**:
   - `ApplicationController` に `before_action :authenticate_user!` を配置し、未認証リクエストを `/login` へリダイレクトする（元の遷移先 URL をセッションに保持してログイン後復帰）。
   - Webhook エンドポイント（`/webhooks/github`）およびヘルスチェック（`/up`）は認証除外を維持し、HMAC-SHA256 署名検証により保護する。
   - ログイン時およびログアウト時に `reset_session` を呼び出し、セッション固定攻撃（Session Fixation）を防止する。

## Consequences

- Basic 認証に依存せず、安全かつ快適にブラウザから GitHub 1 クリックでダッシュボードにログインできる。
- 環境変数の設定変更だけで、許可ユーザーの追加・削除を安全に管理できる。
- 外部 gem の依存を増やさず、Rails の標準規約と最小限のコードで高い保守性を維持できる。
