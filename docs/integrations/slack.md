# Slack 連携

## 1. MVP の対象

初期 MVP では Slack を最初の外部連携先とし、Socket Mode を利用します。

主な機能：

- Slack App へのメンション受信（`app_mention`）
- 既存 Quest Thread へのメンションなし返信の受信（`message` イベントのうち、既存 `ExternalResource` に紐づく `thread_ts` を持つもの）
- メンションまたは返信が属する Thread の特定
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

## 4. 返信とリアクション

Slack への反応・返信は、スレッドがノイジーにならないよう次の流れで行います。

1. **指示受付時（`:eyes:` リアクションの付与）**
   - ユーザーのコメント（メンションまたは既存 Quest Thread への返信）を受け付けた時点で、そのコメント（`ts`）に対して `reactions.add` で `:eyes:` リアクションを付けます。
   - 受付時・実行開始時のテキストコメントは投稿しません。
2. **完了・失敗時（結果の返信と `:eyes:` リアクションの解除）**
   - 完了時は、余分なプレフィックスを付けず Agent の応答テキスト（`result_summary`）のみを Thread に返信します。
   - 失敗・キャンセル時は、エラー理由を Thread に返信します。
   - 返信と同時に、受付時に付けた `:eyes:` リアクションを `reactions.remove` で解除します。

Slack API の rate limit や一時障害を考慮し、通知やリアクション操作の失敗が Agent Execution 全体の成功・失敗を不必要に左右しないようにします。

## 5. 認証情報

Slack Token は omochi のホスト側プロセスでのみ利用します。Agent Container に渡してはいけません。

必要な OAuth scope、Event Subscription、Socket Mode の設定値は、実装時に Slack API の最新仕様を確認して決定します。

## 6. テスト

- Slack SDK の通信部分をテストダブルに置き換えられるようにする。
- Slack の実 credential がなくてもイベント処理と Quest 作成をテストできる。
- Event の重複受信、bot 自身の投稿、Thread 返信、API 失敗をテストする。
