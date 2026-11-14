# ドメインモデル

## 1. モデルの関係

現時点で想定する概念上の関係は次のとおりです。

```text
Quest
  ├── ExternalResource
  ├── QuestInstruction
  ├── QuestExecution
  └── QuestEvent（必要に応じて）
```

これはドメインの責務を整理するためのモデル案です。テーブル構造、関連名、正規化の程度は実装時に検証してください。

## 2. Quest

Quest は一つの仕事を表します。

主な責務：

- omochi 独自の識別子を持つ。
- 状態を持ち、完了後も再開できる。
- 複数の ExternalResource を関連付けられる。
- 複数の Instruction と Execution の履歴を持つ。
- Agent SDK の Session ID や Slack Thread ID を主キーとして使わない。

### Quest ID

Quest ID は外部プラットフォームから独立した、一意な識別子です。

- UUID などの標準的な一意識別子形式を候補とする。
- Active Record の内部主キーと外部公開用 Quest ID を分離する案を基本とする。
- 具体的な形式・接頭辞・長さは未決定。
- Quest ID は識別子であり、認証情報や秘密情報として扱わない。

Slack では Quest 作成時に元の Thread へ Quest ID を返信します。GitHub では後続フェーズで Issue / PR の Description に機械可読な marker を記載する案があります。

外部リソース上の marker は Quest を発見する手掛かりであり、それだけを唯一の正として扱いません。omochi 側の DB にも関連付けを永続化します。

## 3. ExternalResource

Slack Thread、GitHub Issue、GitHub Pull Request など、Quest に関連する外部リソースを表します。

識別に必要な情報の候補：

- platform（例: slack, github）
- resource type（例: thread, issue, pull_request）
- 外部サービス内での resource ID
- repository や workspace などのスコープ情報
- URL（表示・参照用）
- Quest との関連

同じ外部 ID が異なる workspace / repository で衝突しないよう、識別子のスコープを設計してください。

一つの Quest に複数の ExternalResource を関連付けられるようにします。外部リソースの追加・削除・関連付け変更の監査方針は実装時に検討します。

## 4. QuestInstruction

Quest に対するユーザーの依頼・追加指示を表します。

- 受信した指示内容を保持する。
- 受信元のプラットフォーム・イベントを追跡できるようにする。
- 受信順を保持する。
- 実行中の指示を後から暗黙に書き換えない。
- キュー待ち、処理中、処理済み、失敗などの処理状態を表現する。

指示の本文だけでなく、受信元イベント ID、ExternalResource、受信日時など、重複排除と追跡に必要な情報を保存します。

## 5. QuestExecution

Agent が Quest の指示を処理した一回分の実行です。

- 一つの Quest に複数の Execution が存在できる。
- Execution ごとの開始・終了・結果・エラー・ログを保持する。
- Quest の再開時には新しい Execution を作成する。
- 過去の Execution を上書きしない。
- Agent SDK の Session と同一視しない。

初期実装では一つの Instruction を一つの Execution で処理する単純なモデルを推奨します。ただし、将来複数 Instruction をまとめて一回の Execution で処理する可能性を不必要に閉ざさないでください。

## 6. QuestEvent

Quest に起きた重要なイベントを記録する概念です。たとえば Instruction 受信、Execution 開始・終了、状態変更、外部リソース追加などです。

イベント履歴を専用テーブルにするか、Instruction / Execution の状態と作成日時から導出するかは、MVP の要件と監査性を踏まえて決定します。

## 7. Quest と Execution の状態

Quest のライフサイクルと Execution のライフサイクルは独立させます。

Quest の状態候補：

- pending
- running
- completed
- failed
- cancelled

Execution の状態候補：

- queued
- preparing
- running
- succeeded
- failed
- cancelled

上記は検討用の候補であり、最終的な状態名・遷移・失敗後の扱いは未決定です。Quest が completed でも、新しい Instruction を受け付けて再開できます。

## 8. 再開

- 再開時に Quest ID は維持する。
- 過去の Instruction / Execution の履歴を保持する。
- 再開に伴う実行は新しい QuestExecution とする。
- 再開の契機（Slack の返信、明示コマンド、GitHub イベントなど）はイベント種別ごとに定義する。すべての外部イベントを自動的に再開契機にしない。
