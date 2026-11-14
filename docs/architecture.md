# システムアーキテクチャ

## 1. 構成概要

初期構想では、次の役割に分けます。

```text
Slack (Socket Mode) ─▶ omochi-socket ┐
                                     │
Browser (Dashboard) ─▶ omochi-web ───┼─▶ Quest / SQLite
                                     │        │
GitHub (Webhook) ───▶ omochi-web ────┘        ▼
                                           Solid Queue
                                               │
                                               ▼
                                         omochi-worker
                                               │
                                               ▼
                                      Quest Agent Container
                                               │
                                      structured events
                                               │
                                               ▼
                                      omochi-worker / DB
                                               │
                               Slack / Dashboard へ反映
```

GitHub は後続フェーズの対象です。初期 MVP では Slack と Dashboard の経路を完成させます。

上記の `omochi-web`、`omochi-socket`、`omochi-worker` は論理的な役割を示します。Rails プロセスを実際に何個に分割するか、同一 Rails アプリを複数の起動コマンドで動かすかは、運用・テスト上の利点を比較して決定します。

## 2. コンポーネントの責務

### omochi-web

- Dashboard の HTTP リクエストを処理する。
- 将来の GitHub Webhook を受け付ける。
- Quest と関連データを表示する。
- Turbo Streams などを使って更新をブラウザへ通知する。

### omochi-socket

- Slack Socket Mode の接続を維持する。
- Slack Event を受信し、入力を検証する。
- 重複イベントを識別し、Quest / Instruction の作成を依頼する。
- Slack への返信を行う、または送信 Job を enqueue する。

Slack SDK の接続維持と Rails のライフサイクルをどう統合するかは、実装時に検証します。

### omochi-worker

- Solid Queue の Job を実行する。
- Quest の Instruction Queue を順番に処理する。
- Agent Container の作成、起動、イベント取得、終了、cleanup を管理する。
- 実行結果を DB に保存する。
- 必要に応じて Slack など外部サービスへの通知を依頼する。

### Agent Container

- Quest の作業を実行する隔離環境。
- 初期 MVP では Mock Agent を実行する。
- stdout などを通じて構造化イベントを omochi に返す。
- Slack / GitHub の認証情報や Docker Socket を持たない。

### Dashboard

- Quest の一覧、状態、詳細を表示する。
- Instruction と Execution の履歴を表示する。
- Execution の進捗・ログ・結果を表示する。
- Rails Views と Hotwire を基本とする。

## 3. データフロー

### 新しい依頼

1. Slack Event を受信する。
2. Slack Event の重複を検査する。
3. 対応する Quest が存在するか判定する。
4. 新規の場合は Quest と ExternalResource を作成する。
5. QuestInstruction を永続化する。
6. 必要な Job を enqueue する。
7. Slack Thread に Quest ID と受付結果を返信する。

DB の永続化と Job enqueue の間で不整合が起きないよう、enqueue のタイミングや再試行方法を設計してください。永続化前に処理を開始してはいけません。

### Agent Execution

1. Worker が Quest の次の処理対象 Instruction を取得する。
2. 同じ Quest の Execution が並行しないことを保証する。
3. QuestExecution を作成し、実行開始を記録する。
4. Docker Engine を通じて実行環境を用意する。
5. Mock Agent を起動し、構造化イベントを受け取る。
6. イベントを永続化し、Quest / Execution の状態を更新する。
7. 完了・失敗を記録し、必要な通知を行う。
8. Container と一時リソースを cleanup する。
9. 次の Instruction があれば処理を継続する。

## 4. 永続化とキュー

SQLite をアプリケーションの永続状態の基盤とします。Solid Queue を非同期処理に利用します。

ただし、Solid Queue の Job 順序だけを Quest 単位の FIFO 保証として扱ってはいけません。Quest ごとの排他制御と次の Instruction の選択は、アプリケーションのドメイン規則として実装します。

SQLite のロック、複数プロセスからのアクセス、Solid Queue の DB 構成・接続設定を早期に検証してください。複数ホストでの分散実行は初期 MVP の対象外です。

長時間の Agent 実行中に DB トランザクションを開き続けてはいけません。状態遷移の短い単位でトランザクションを使用します。

## 5. 依存関係の方針

- Rails と公式エコシステムの機能を優先する。
- UI は Rails Views + Hotwire を基本とする。
- Redis や外部メッセージブローカーは、必要性が実証されるまで導入しない。
- フロントエンドの大規模な独立アプリケーション化を避ける。
- Agent SDK はドメイン層から隔離し、後から差し替え可能にする。
