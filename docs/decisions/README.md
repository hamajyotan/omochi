# Architecture Decision Records

このディレクトリには、omochi の重要な設計判断を時系列で記録します。

## 方針

- ADR は原則として一つの設計判断を扱う。
- 状態は Proposed / Accepted / Superseded / Deprecated などで明記する。
- Accepted の ADR は原則として書き換えない。
- 既存の判断を変更する場合は、新しい ADR を作成し、置き換える ADR へのリンクと変更理由を記載する。
- 小さな実装詳細や一時的なメモをすべて ADR にする必要はない。

## ファイル名

```text
NNNN-short-title.md
```

例：`0001-quest-independent-identity.md`

## ADR テンプレート

```markdown
# NNNN: タイトル

- Status: Proposed
- Date: YYYY-MM-DD

## Context

背景・解決したい問題。

## Decision

採用する判断。

## Consequences

メリット、デメリット、制約、今後の影響。
```

現時点では、プロジェクトの初期方針をこの ADR 群に重複して転記していません。今後、実装上の比較検討を経て確定した判断から記録してください。
