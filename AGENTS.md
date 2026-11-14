# omochi — AI コーディングエージェント向け指示書

このファイルは、`omochi` の開発に参加する AI コーディングエージェント向けの最上位指示書です。詳細な背景・設計・運用方針は `docs/` 配下を参照してください。

## 1. プロジェクトの目的

`omochi` は、複数のプラットフォームをまたいで一つの仕事を継続的に管理し、AI Agent に実行させるアシスタント基盤です。

omochi が管理する中心的な対象は「会話」ではなく「仕事」です。

- Slack Thread や GitHub Issue / Pull Request は、仕事に関連付けられる外部リソースです。
- Quest は仕事そのものを表す omochi 独自のドメイン概念です。
- Agent の実行は Quest に付随する処理であり、Quest と同一ではありません。
- 一つの Quest は複数のプラットフォームや複数回の Agent Execution にまたがって継続します。

## 2. 開発時に必ず守ること

1. **既存コードを先に調べる。** 実装前にリポジトリ構成、既存の規約、依存関係、テスト方法を確認する。
2. **不明点を勝手に確定しない。** `docs/open-questions.md` に記載された未決事項は、根拠なく決め打ちしない。実装に不可欠な場合は、選択肢とトレードオフを提示する。
3. **小さく段階的に実装する。** 一度に大規模な変更を行わず、動作確認可能な単位で進める。
4. **Rails の標準機能と規約を優先する。** 独自フレームワークや不要な抽象化、不要な依存 gem を追加しない。
5. **テストを先に考える。** ドメインロジックは Minitest で検証する。外部サービスに依存せずテストできる設計にする。
6. **セキュリティ境界を守る。** Agent Container に Slack / GitHub の認証情報や Docker Socket を渡さない。
7. **永続化された状態を正とする。** Docker Container の状態だけを Quest や Execution の状態管理に使わない。
8. **秘密情報をコミットしない。** `.env` は Git 管理対象外とし、`.env.example` には値ではなく設定項目と説明を記載する。
9. **ドキュメントと実装を同期する。** 設計判断を変更した場合は関連ドキュメントも更新する。承認済みの設計判断を変更するときは、既存記録を黙って書き換えず、新しい ADR で変更理由を記録する。
10. **完了を誇張しない。** 実行したテスト、未実施の確認、既知の制約を明確に報告する。

## 3. 技術方針

初期 MVP では次を基本方針とします。

- Ruby on Rails
- SQLite
- Active Record
- Active Job / Solid Queue
- Hotwire（Turbo / Stimulus）
- Rails Views を中心とした HTML-first の UI
- Linux + Docker Engine / Docker Compose
- Slack Socket Mode
- Agent は Quest ごとの隔離された Docker 実行環境で動かす
- 初期 Agent は Mock Agent とし、実際の Agent SDK は後続フェーズで選定する
- GitHub 連携は Slack を中心とした MVP の後に実装する

React、Vue、Redis、外部メッセージブローカーなどは、明確な必要性が確認できない限り導入しません。

## 4. ドメイン上の不変条件

- Quest は Slack Thread や GitHub Issue のラッパーではない。
- Quest は omochi 独自の識別子を持つ。外部プラットフォームの ID を Quest ID として流用しない。
- 一つの Quest に複数の External Resource を関連付けられる。
- Quest が完了した後も、同じ Quest を再開できる。再開時に Quest ID は変えない。
- 再開時の Agent 実行は新しい QuestExecution とし、過去の Execution 履歴を保持する。
- 一つの Quest 内で Agent Execution を同時に複数実行しない。
- 実行中に受け取った追加指示は、現在の実行へ割り込ませず、永続化したうえで受信順に処理する。
- Quest の状態と QuestExecution の状態は別々に管理する。

詳細は `docs/domain-model.md` と `docs/execution.md` を参照してください。

## 5. MVP の範囲

MVP の対象は以下です。

1. Rails アプリケーションと SQLite / Solid Queue の基盤
2. Quest と関連ドメインモデル
3. 基本的な Dashboard
4. Docker Engine を使った Agent Container の起動・監視・終了
5. Container 内で動作する Mock Agent
6. Slack Socket Mode によるメンション受信と Thread への返信
7. 進捗・ログ・実行結果の永続化と Dashboard への反映

初期 MVP では、GitHub Webhook、実際の Pull Request 作成、実 Agent SDK の統合は対象外です。

## 6. 実装開始時の進め方

新しいタスクに着手するときは、次の順で進めてください。

1. 関連するコードと `docs/` の記述を読む。
2. 要件、既存実装、影響範囲、未決事項を整理する。
3. 必要に応じて実装方針と小さな作業計画を提示する。
4. 既存の設計方針に沿って実装する。
5. 関連するテストを追加・更新し、実行する。
6. 必要なドキュメントを更新する。
7. 変更内容、テスト結果、残課題を報告する。

初回の作業では、いきなり大規模な実装を始めず、リポジトリの現状を調査したうえで Phase 1 の具体的な実装計画を提示してください。

## 7. ドキュメント構成

- `docs/README.md`: ドキュメント案内
- `docs/overview.md`: プロダクトの目的と用語
- `docs/architecture.md`: システム構成と責務
- `docs/domain-model.md`: Quest を中心とするドメインモデル
- `docs/execution.md`: Instruction Queue と Execution の実行規約
- `docs/integrations/slack.md`: Slack 連携
- `docs/integrations/github.md`: 将来の GitHub 連携
- `docs/security.md`: セキュリティ境界
- `docs/roadmap.md`: 開発フェーズと MVP 完了条件
- `docs/open-questions.md`: 未決事項
- `docs/decisions/`: 重要な設計判断の記録（ADR）
