# Slack 連携

## 1. MVP の対象

初期 MVP では Slack を最初の外部連携先とし、Socket Mode を利用します。

主な機能：

- Slack App へのメンション受信
- メンションが属する Thread の特定
- Quest の作成または既存 Quest への関連付け
- QuestInstruction の登録
- Thread への受付・進捗・完了・失敗の返信

## 2. Quest との関連付け

Slack Thread は Quest そのものではありません。Slack Thread は Quest に関連付けられる ExternalResource の一つです。

新しい Quest を作成した場合、omochi は独自の Quest ID を発行し、元の Thread に Quest ID を含む返信を行います。

返信例（文言は実装時に調整可能）：

```text
🍡 Quest created: qst_...
```

Thread 内の後続メッセージをどのように既存 Quest に結び付けるかは、Slack Event の種類、Thread 情報、保存済み ExternalResource の関連を使って判断します。Quest ID の文字列だけを認証・認可の根拠にしてはいけません。

## 3. イベント受信

- Slack Event の署名・送信元を検証する。
- Slack が同じイベントを再送する可能性を前提にする。
- Event ID 等を用いて重複処理を防ぐ。
- Event の受信と Agent Execution を同期処理にしない。
- 受信した指示は永続化してから非同期処理に渡す。
- bot 自身の投稿や対象外イベントを誤って新しい指示として処理しない。

Socket Mode の ACK は Slack の再送制御に関係するため、ACK のタイミングと DB 永続化の順序を明確にしてください。処理を受け付けたと Slack に応答する前に、イベントを失わない設計にします。

## 4. 返信

Slack への返信は、受信元 Thread に紐づけて行います。

- Quest 作成・指示受付
- 実行開始
- 必要に応じた進捗
- 完了
- 失敗・タイムアウト

通知の頻度やログのどこまでを Slack に出すかは未決定です。大量の stdout をそのまま投稿せず、要約や重要イベントを中心に通知してください。

Slack API の rate limit や一時障害を考慮し、通知失敗が Agent Execution 全体の成功・失敗を不必要に左右しないようにします。

## 5. 認証情報

Slack Token は omochi のホスト側プロセスでのみ利用します。Agent Container に渡してはいけません。

必要な OAuth scope、Event Subscription、Socket Mode の設定値は、実装時に Slack API の最新仕様を確認して決定します。

## 6. テスト

- Slack SDK の通信部分をテストダブルに置き換えられるようにする。
- Slack の実 credential がなくてもイベント処理と Quest 作成をテストできる。
- Event の重複受信、bot 自身の投稿、Thread 返信、API 失敗をテストする。
