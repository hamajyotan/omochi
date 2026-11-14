# プロダクト概要

## 1. omochi とは

omochi は、複数のプラットフォームをまたいで一つの仕事を継続的に管理し、AI Agent に実行させるアシスタント基盤です。

Slack で始まった依頼を、後から GitHub Issue や Pull Request と関連付けることがあります。その場合でも、プラットフォームごとに別の仕事として扱うのではなく、一つの Quest として継続管理します。

omochi が管理する中心的な対象は「会話」ではなく「仕事」です。会話、外部リソース、Agent の実行履歴は、仕事を進めるために Quest に付随する情報です。

## 2. 基本概念

### Quest

一つの仕事を表す omochi 独自のドメインモデルです。Slack Thread や GitHub Issue のラッパーではありません。

Quest は独自の識別子を持ち、完了後も再開できます。Quest の識別子は、外部プラットフォームの ID や Agent SDK の Session ID から独立しています。

### QuestInstruction

ユーザーや外部イベントから受け取った依頼・追加指示です。Quest に対する指示を受信順に永続化します。

### QuestExecution

Agent が Quest の指示を処理した一回分の実行です。一つの Quest に複数の Execution が存在し、過去の実行履歴を保持します。

### Agent Session

Agent SDK が管理する会話・実行コンテキストです。Quest や QuestExecution と同一の概念ではありません。採用する Agent SDK によって、保存・再開・破棄の方法が変わります。

### External Resource

Slack Thread、GitHub Issue、GitHub Pull Request など、Quest に関連付けられる外部プラットフォーム上のリソースです。

### QuestEvent

Quest に発生したイベントの履歴です。指示の受信、Execution の開始・終了、状態変更などを記録する用途を想定します。専用モデルにするか、他の永続化データから導出するかは実装時に判断できます。

## 3. 設計原則

1. **仕事を中心にする**: 外部プラットフォームの会話構造を、omochi のドメインモデルの中心に置かない。
2. **プラットフォームから独立させる**: Quest は Slack や GitHub の ID に依存しない。
3. **履歴を保持する**: 再開や再実行によって過去の Execution や指示を上書きしない。
4. **非同期実行を前提にする**: 外部イベントの受信と Agent の実行を分離する。
5. **永続状態を正とする**: プロセスや Container の生存状態だけに依存しない。
6. **段階的に拡張する**: 最初は Slack と Mock Agent に絞り、後から GitHub や実 Agent SDK を追加できる境界を設ける。

## 4. MVP の利用イメージ

1. Slack で omochi にメンションする。
2. omochi が新しい Quest を作成し、独自の Quest ID を発行する。
3. omochi が元の Slack Thread に Quest ID を含む返信をする。
4. Quest に対する指示をキューに登録する。
5. Worker が Quest の実行を開始し、Quest 専用の Docker 実行環境で Mock Agent を動かす。
6. Mock Agent が進捗やログ、完了結果を構造化イベントとして出力する。
7. omochi がイベントを永続化し、Dashboard と Slack Thread に反映する。
8. 実行環境を終了・片付ける。

同じ Quest に追加指示が届いた場合は、新しい指示としてキューに登録します。実行中の処理には割り込ませず、現在の Execution が終わった後に順番に処理します。
