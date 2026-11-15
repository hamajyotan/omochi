# 開発ロードマップ

## 1. MVP の方針

最初から実 Agent SDK や GitHub 連携まで実装せず、Quest のライフサイクルと Docker 実行基盤を Mock Agent で検証します。

Mock Agent であっても、ホスト内プロセスとして動かすだけではなく、実際に Docker Engine で Container を起動して実行します。

## 2. フェーズ

### Phase 1: Rails 基盤と Quest ドメイン

- Rails アプリケーションの初期化
- SQLite / Active Record / Solid Queue の構成
- Quest と必要な関連モデル
- Quest ID の発行
- Quest の一覧・詳細を表示する基本 Dashboard
- Minitest によるドメインテスト
- `.env.example` と設定読み込み

完了の目安：Slack や Docker がなくても、Quest と Instruction を作成・参照できる。

### Phase 2: Docker 実行基盤

- Docker Engine との連携
- Quest / Execution に対応する Container lifecycle
- workspace の準備と cleanup
- Mock Agent の実装
- stdout 等を使った構造化イベントプロトコル
- 進捗・ログ・結果の永続化
- timeout、異常終了、cleanup 失敗の扱い

完了の目安：テスト可能な入力から Quest Execution を起動し、Container 内の Mock Agent のイベントと終了結果を DB に保存できる。

### Phase 3: Slack 連携

- Slack Socket Mode 接続
- メンション受信
- Event の検証と重複排除
- Quest / ExternalResource / Instruction の作成
- Thread への Quest ID 返信
- Execution の受付・開始・完了・失敗通知

完了の目安：Slack のメンションから Mock Agent の実行が開始され、同じ Thread に結果が返信される。

### Phase 4: Dashboard の完成

- Quest の状態と履歴
- Instruction Queue
- Execution の履歴・状態
- 進捗イベントとログ
- Turbo Streams 等による更新
- エラー表示と再開の導線

完了の目安：ブラウザから Quest の状態、指示、実行履歴、進捗、結果を確認できる。

### Phase 5: GitHub 連携（MVP 後）

- 単一 repository の設定
- GitHub Webhook（署名検証と重複排除）
- Issue / PR と Quest の関連付け
- PR レビュー起動（スラッシュコマンド `/review` / `/omochi`）
- Pull Request Review API による結果返信
- Slack から始まった Quest と GitHub リソースの相互関連付け

### Phase 6: Dashboard 認証の刷新（MVP 後）

- 認証方式の選定（GitHub OAuth / Google OAuth / Cloudflare Access / Slack 認証 等の比較・決定）
- 認可ポリシーの設計（許可ユーザーリスト、Organization 制限、メールドメイン制限など）
- 認証機構の実装・導入（Rails 内 OAuth またはエッジ/プロキシ層による保護）
- Webhook エンドポイント（`/webhooks/github` 等）の認証除外・署名検証の維持
- ログイン・セッション管理・ログアウト・認可外アクセスの遮断テスト
- 本番環境での Basic 認証撤廃と SSO 移行

完了の目安：Nginx の Basic 認証を撤廃し、許可されたメンバーのみが SSO で安全に Dashboard へログイン・操作できる。

### Phase 7: Antigravity Agent の統合（MVP 後）

- Agent コアエンジンに Google Antigravity（Python SDK `google-antigravity`）を採用
- Antigravity 実行用 Dockerfile / Agent Container イメージの作成
- Instruction を Antigravity Agent へ入力し、思考プロセス（`response.thoughts`）やツール実行（`response.tool_calls`）を omochi の JSONL プロトコルへ変換して stdout 出力するアダプターの実装
- LLM 認証情報（API キー等）の安全なコンテナ注入
- ワークスペース内での自律ツール実行（ファイル編集・コマンド実行・Git 操作）の検証
- Mock Agent から Antigravity 実 Agent への切り替え
- PR レビューや Slack 指示における実 AI レビュー・自律改修の End-to-End 動作確認

## 3. MVP の End-to-End 完了条件

次の流れが一通り動作することを MVP の主要な完了条件とします。

1. Slack で omochi にメンションする。
2. Quest が作成され、独自 Quest ID が発行される。
3. 元の Slack Thread に Quest ID を含む返信が行われる。
4. Instruction が永続化され、Solid Queue によって処理される。
5. Quest に対応する Docker Container が起動する。
6. Container 内で Mock Agent が実行される。
7. Mock Agent の progress event / log / result が永続化される。
8. Dashboard に実行状況が反映される。
9. Slack の元 Thread に進捗または完了結果が返信される。
10. Container と一時リソースが cleanup される。

## 4. MVP の対象外

- GitHub Webhook と実際の PR 作成
- 実 Agent SDK の統合
- 複数 repository
- 複数 Agent の協調実行
- Agent の自動選択
- 複数ホストへの分散実行
- 本番 HA / マルチテナント
- Agent Container への Slack / GitHub credential の直接注入
