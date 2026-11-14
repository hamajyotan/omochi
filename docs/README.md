# omochi ドキュメント

このディレクトリには、omochi のプロダクト構想、アーキテクチャ、ドメインモデル、外部連携、開発計画を記載します。

## ドキュメント一覧

| ファイル | 内容 |
|---|---|
| [overview.md](overview.md) | プロダクトの目的、基本概念、用語 |
| [architecture.md](architecture.md) | システム構成、各コンポーネントの責務、データフロー |
| [domain-model.md](domain-model.md) | Quest、Instruction、Execution、外部リソース |
| [execution.md](execution.md) | 指示のキューイング、Execution の直列化、失敗・再開 |
| [integrations/slack.md](integrations/slack.md) | Slack Socket Mode による連携 |
| [integrations/github.md](integrations/github.md) | 将来の GitHub Webhook / Issue / PR 連携 |
| [security.md](security.md) | Docker、認証情報、外部通信のセキュリティ |
| [roadmap.md](roadmap.md) | MVP の開発フェーズと完了条件 |
| [open-questions.md](open-questions.md) | まだ決定していない設計事項 |
| [decisions/](decisions/) | 重要な設計判断の記録 |

## 設計情報の読み方

- **決定済み**: 現時点でプロジェクト方針として合意されている事項。
- **方針**: 採用する方向性は決まっているが、実装詳細に裁量が残る事項。
- **未決定**: 実装前または該当フェーズまでに判断する事項。

未決定事項を、ドキュメントに書かれているという理由だけで確定事項として扱わないでください。

## ドキュメントの更新

設計や実装の変更に合わせて、関連ドキュメントを更新してください。重要な設計判断を後から変更する場合は、過去の ADR を書き換えるのではなく、新しい ADR を追加して変更理由と移行方針を記録します。
