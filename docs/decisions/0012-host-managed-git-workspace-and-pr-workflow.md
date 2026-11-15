# 0012: ホスト主導の Git ワークスペース同期と `git commit` トリガーによる Pull Request 自動作成

- Status: Accepted
- Date: 2026-11-15

## Context

Phase 7 で Antigravity Agent ランタイムを統合したが、Agent Container にマウントされる `/workspace` には指示ファイル（`.omochi_instruction.json`）しか存在しないため、以下の課題があった。

1. GitHub Pull Request 上で `/review` を実行しても、Agent が対象リポジトリのソースコードや PR の差分（diff）を参照できない。
2. Slack や GitHub Issue / PR から機能開発・修正を依頼しても、Agent がコードベースを編集して Pull Request を提出する経路がない。
3. 一方で、`docs/security.md` の原則により、GitHub App の秘密鍵や Installation Access Token を Agent Container に直接渡すことは禁止されている。

## Decision

1. **ホスト主導での Git ワークスペース準備（Milestone 8-1）**:
   - GitHub App の認証情報はホスト側（`omochi-worker`）のみが保持し、コンテナ起動前にホスト側が対象リポジトリを Quest の `/workspace` に clone / fetch する。
   - ホスト側での `git clone` / `git fetch` / `git push` 実行時は `git -c http.extraHeader="Authorization: basic ..."` による一時ヘッダ注入を使用し、`/workspace/.git/config` には認証トークンを一切書き込まない。
   - Quest に GitHub Pull Request の `ExternalResource` が関連付けられている場合は、該当 PR の head ref をチェックアウトした上で、PR の unified diff を `/workspace/.omochi_pr.diff` として配置する。

2. **`git commit` トリガー方式（案 A）によるホスト側自動 Push & PR 作成（Milestone 8-2）**:
   - Agent Container 内では、Agent は通常のファイル編集およびローカルの `git commit` のみを行う（外部への `git push` や GitHub API 呼び出し権限は持たない）。
   - コンテナが正常終了した後、ホスト側（`omochi-worker`）が `/workspace` の `HEAD` が実行開始時点より前進しているか（新しいローカルコミットが存在するか）を検査する。
   - 新しいローカルコミットが存在する場合、ホスト側が自動的に作業ブランチ（`omochi/<quest_public_id>` または既存 PR ブランチ）へ `git push` し、Quest に Pull Request の `ExternalResource` が未関連付けであれば GitHub API で新規 Pull Request（`<!-- omochi:quest=qst_... -->` マーカー付き）を自動作成して `ExternalResource` として関連付ける。
   - 調査や質問回答のみで新しいローカルコミットが作成されなかった場合は、ホスト側は Push や PR 作成を行わない。

## Consequences

- Agent Container に GitHub 認証情報を一切渡さないセキュリティ境界を維持したまま、PR の実コードレビューと Agent による自律的な機能開発・PR 提出の両方が可能になる。
- PR 作成のトリガーを「Agent が `git commit` したかどうか」という Git の客観的状態に置くことで、独自 JSON シグナルの出力忘れによる空振りを防ぎつつ、調査のみの実行で不要な PR が作られることも防止できる。
