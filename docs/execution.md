# Instruction Queue と Agent Execution

## 1. 基本方針

同じ Quest に対する Agent Execution は直列に実行します。一つの Quest について、同時に複数の Agent Execution を動かしません。

実行中に追加指示を受け取った場合、現在の Execution に割り込ませず、QuestInstruction として永続化し、現在の Execution が終了した後に処理します。

## 2. キューイング規則

- Instruction は受信順に処理する。
- Instruction は受信時点で永続化する。
- 実行中の Instruction の内容を、後から受信した指示で変更しない。
- 同一 Quest に複数イベントが同時到着しても、二重実行しない。
- アプリケーションや Worker の再起動後もキュー状態を復元できる。
- 完了・失敗した Quest に新しい有効な Instruction が到着した場合、同じ Quest を再開して新しい Execution をスケジュールする。

FIFO の定義は、原則として omochi が Instruction を受理し永続化した順序とします。外部プラットフォームのイベント発生時刻だけを順序の根拠にしないでください。

## 3. 排他制御

Solid Queue の Job 実行順序だけでは、Quest 単位の直列実行は保証できません。

アプリケーション側で以下を保証してください。

1. Quest ごとに実行中 Execution が最大一つである。
2. 次の Instruction の取得と Execution の作成が競合しない。
3. 同じ Job が再実行されても二重に Execution を開始しない。
4. Worker が異常終了した場合に、実行中状態を検出して回復できる。
5. Job の enqueue と DB 更新の間に障害が起きても、処理対象が失われない。

SQLite のトランザクション、ユニーク制約、短時間の claim 処理などを組み合わせて実装してください。SQLite の書き込みロックを長時間保持する設計は避けます。

## 4. 推奨する初期実装モデル

初期段階では、次の単純なモデルを推奨します。

- QuestInstruction は一つずつ永続化する。
- Worker は Quest の次の未処理 Instruction を claim する。
- claim と QuestExecution 作成を原子的に行う。
- 一つの Instruction を一つの Execution で処理する。
- Execution 終了後に次の Instruction があれば、次の処理をスケジュールする。

将来、複数 Instruction をまとめて一回の Execution で処理する場合でも、Instruction 自体の履歴を失わない設計にします。

## 5. Execution の流れ

1. Instruction を claim する。
2. QuestExecution を作成する。
3. Quest / Execution の開始状態を保存する。
4. Docker Container を準備する。
5. Agent Process を起動する。
6. 構造化イベントを受信・永続化する。
7. Agent の終了コードと最終イベントを確認する。
8. Execution の成功・失敗を確定する。
9. Quest の状態を更新する。
10. Container と一時リソースを cleanup する。
11. 次の Instruction があれば処理を継続する。

外部プロセスの終了と DB 更新の間には障害が起き得ます。再起動後に状態を照合できるよう、Execution の開始情報、Container の識別情報、heartbeat / timeout の方針を設計してください。

## 6. 失敗・キャンセル・再試行

失敗時に Instruction を自動で無限再試行してはいけません。少なくとも以下を区別できるようにします。

- Agent が正常終了しなかった。
- Container の起動や接続に失敗した。
- Worker が異常終了した。
- タイムアウトした。
- ユーザーがキャンセルした。
- 外部通知だけが失敗した。

再試行する場合は、同じ Execution の再実行なのか、新しい Execution を作成するのかを明確にします。実行履歴を保持するため、原則として再実行は新しい Execution として記録する方針を検討してください。

失敗した Quest に新しい Instruction が届いた場合の再開と、失敗した Instruction 自体の再試行は別の操作として扱います。

## 7. Job の設計

- Job は重複実行される可能性があるものとして設計する。
- Job の引数には、再取得可能な永続レコードの ID を渡す。
- Job 内で外部処理を行う前に、対象レコードの状態と実行権を確認する。
- 長時間処理を DB トランザクションで囲まない。
- Job が失敗しても、DB 上に処理の痕跡が残るようにする。
