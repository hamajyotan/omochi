# GitHub 連携（後続フェーズ）

## 1. 位置付け

GitHub 連携は初期 MVP の対象外です。Slack と Mock Agent を中心とした MVP が成立した後に実装します。

初期の GitHub 対象は単一リポジトリとします。複数リポジトリ対応は初期スコープに含めません。

## 2. 想定する機能

- GitHub Webhook の受信
- Issue / Pull Request と Quest の関連付け
- Slack で始まった Quest に GitHub Issue / PR を追加
- GitHub 側で発生したイベントを既存 Quest の Instruction として扱う
- Quest の進捗や結果を GitHub 側へ反映する

実際のイベント種別、書き込み権限、通知内容は後続フェーズで決定します。

## 3. Quest marker 案

GitHub Issue / Pull Request の Description に、機械可読な marker を記載する案があります。

```html
<!-- omochi:quest=qst_... -->
```

marker は Quest と GitHub リソースの関連付けを発見するための手掛かりです。marker が存在するだけで信頼せず、Webhook の署名、対象 repository、保存済み ExternalResource との整合性などを検証します。

omochi の DB にも関連付けを永続化し、GitHub 上の Description を唯一の正としません。

## 4. セキュリティと認証

GitHub Token / App credential は omochi のホスト側で管理します。Agent Container に直接渡さないでください。

Agent が GitHub に変更を加える必要が生じた場合は、権限を限定した broker や MCP 等を介する方式を検討します。具体的な方式は未決定です。

## 5. 将来の拡張

GitHub 連携を追加しても、Quest が GitHub Issue や PR に従属するモデルに変更してはいけません。外部リソースの追加によって同じ Quest の仕事を継続できることが重要です。
