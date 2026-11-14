# 0008: Systemd User Services と GitHub Actions による自動デプロイ

- Status: Accepted
- Date: 2026-11-14

## Context

初期デプロイでは、システム全体（`/etc/systemd/system/`）に root 権限で Systemd ユニットを配置していたため、デプロイやサービス再起動のたびに root 権限（SSH または sudo）が必要となり、CI/CD からの安全な自動デプロイが困難だった。

## Decision

1. **Systemd User Services（`systemctl --user`）の採用**:
   - `omochi-web`, `omochi-worker`, `omochi-socket` の管理を root 権限から切り離し、`omochi` ユーザー固有のユーザーインスタンス（`~/.config/systemd/user/`）で運用する。
   - `loginctl enable-linger omochi` を有効化し、SSH ログアウト後もサービスを常駐させる。
2. **デプロイスクリプト（`bin/deploy`）の提供**:
   - `omochi` ユーザー権限で実行できる冪等なシェルスクリプト `bin/deploy` を用意し、`git fetch/reset`、`bundle install`、`db:prepare`、`assets:precompile`、および `systemctl --user restart` を一連のフローとしてカプセル化する。
3. **GitHub Actions による自動デプロイパイプライン**:
   - `.github/workflows/deploy.yml` を配置し、`main` ブランチへの push をトリガーとして Minitest、RuboCop、Brakeman を実行。
   - 全検証を通過した場合にのみ、デプロイ専用の非特権 SSH 鍵を用いて VPS に接続し、`~/omochi/bin/deploy` を実行する。

## Consequences

- デプロイの自動化に root 権限が不要になり、CI/CD シークレットの漏洩リスクが最小化される。
- GitHub への push だけで自動テストとゼロオペレーションでの本番反映が実現する。
- 巨大なデプロイフレームワーク（Capistrano 等）を追加せず、リポジトリ内のコードと標準的な Linux ツールのみで保守可能となる。
