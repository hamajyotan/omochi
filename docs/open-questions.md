# 未決事項

このファイルは、現時点で方針が確定していない事項を管理します。実装上の都合だけで暗黙に決定せず、必要なタイミングで選択肢とトレードオフを整理してください。

## 1. Quest ID

- UUID v4 / UUID v7 / ULID / その他のどれを採用するか。
- 外部表示用の接頭辞（例: `qst_`）を付けるか。
- 内部主キーと外部公開 ID の具体的な構成。

## 2. Quest と Instruction の状態遷移

- Quest / Instruction / Execution の最終的な status 一覧。
- completed / failed / cancelled の Quest に新しい指示が来たときの遷移。
- Instruction の失敗と Quest の失敗をどう区別するか。
- ユーザーによるキャンセルと再開の操作方法。

## 3. Instruction と Execution の対応

- MVP は 1 Instruction : 1 Execution を基本とする。
- 複数 Instruction を一つの Execution にまとめる将来拡張をどの程度考慮するか。
- 失敗した Instruction を再実行する際、同じ Instruction を再試行するか、新しい Instruction を作るか。

## 4. Slack のイベントと Quest の関連付け

- Thread 内のどの種類のメッセージを追加指示として扱うか。
- Quest ID を含む返信をどのように発見・解釈するか。
- bot 自身の投稿、編集、削除、ファイル添付などをどう扱うか。
- Thread 以外の DM / channel message を対象にするか。
- Slack Event の ACK と DB 永続化の順序。

## 5. Docker 実行環境

- Container を Quest 単位で再利用するか、Execution ごとに作成するか。
- workspace の永続化と cleanup の単位。
- Container の network access をどこまで許可するか。
- CPU / memory / process / timeout の初期上限。
- Container 内のユーザー、filesystem、capability の設定。

## 6. プロセス構成と SQLite

- `omochi-web` / `omochi-socket` / `omochi-worker` をどのように起動・分割するか。
- Solid Queue の DB をアプリケーション DB と共有するか、分離するか。
- SQLite の複数プロセス同時アクセスと lock contention の許容範囲。
- WAL mode 等の SQLite 設定とバックアップ方針。
- Job enqueue と DB transaction の整合性をどう担保するか。

## 7. Agent SDK / Agent Session

- Claude / Codex / その他のどの SDK / CLI を採用するか。
- Session の永続化・再開・破棄をどう扱うか。
- Agent event の標準化方法。
- 外部サービス操作を broker / MCP のどちらで提供するか。

## 8. GitHub 連携

- GitHub App / fine-grained PAT 等の認証方式。
- Webhook の対象イベント。
- Issue / PR Description marker の形式と更新規則。
- 単一 repository の設定方法。
- GitHub への進捗・結果の反映方法。

## 9. 運用・UI

- Dashboard の認証方式。
- ログの保存期間と表示・検索方法。
- Slack への進捗通知の頻度・粒度。
- Quest の手動作成・手動再開・キャンセルの UI。
- バックアップ・復旧手順。

## 決定事項の記録

重要な設計判断を確定したら `docs/decisions/` に ADR を追加し、このファイルの該当項目を更新してください。
