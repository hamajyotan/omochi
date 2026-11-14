# 0001: Quest ID の形式と内部主キーとの分離

- Status: Accepted
- Date: 2026-11-14

## Context

`omochi` の Quest は外部プラットフォーム（Slack Thread、GitHub Issue / PR 等）の ID から独立した独自の識別子を持つ必要がある。URL、Slack 返信、GitHub marker などの外部公開用 ID と、Active Record の内部主キーをどのように設計するかを決める必要があった。

## Decision

- `quests` テーブルの内部主キーは Active Record 標準の整数 `id` とし、外部公開用の識別子として `public_id` カラム（UNIQUE / NOT NULL / 変更不可）を別に持つ。
- `public_id` の形式は `qst_` + UUID v7（`SecureRandom.uuid_v7`）とする（例: `qst_01a1d836-32e2-7137-bec7-62f416cec9e0`）。
- Dashboard の URL（`Quest#to_param`）や外部表示では常に `public_id` を使い、内部主キー `id` による URL 参照は受け付けない。

## Consequences

- Ruby 標準ライブラリのみで生成でき、追加 gem が不要。
- `qst_` 接頭辞によりログ・Slack・GitHub marker 上で Quest ID であることが一目で判別できる。
- UUID v7 は先頭にミリ秒タイムスタンプを持つため大まかな作成順のソート性を備える。
- 内部結合（外部キー）は整数 `id` を使うため SQLite 上のインデックスと結合が軽量に保たれる。
