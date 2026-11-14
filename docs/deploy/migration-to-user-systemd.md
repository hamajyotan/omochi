# システムレベル Systemd から `systemctl --user` への移行手順書

現在、システム全体（`/etc/systemd/system/`）で起動している `omochi-web`, `omochi-worker`, `omochi-socket` を、root 権限不要の **ユーザーインスタンス（`systemctl --user`）** へ安全に移行する手順です。

移行作業は数分で完了し、以後は `omochi` ユーザーおよび GitHub Actions からの自動デプロイが可能になります。

---

## Step 1: root ユーザーでの移行準備（root で作業）

まずは VPS に SSH で root ログインします。

```bash
ssh root@133.18.115.252
```

### 1-1. 旧システムサービスを停止 & 無効化
```bash
systemctl stop omochi-web omochi-worker omochi-socket
systemctl disable omochi-web omochi-worker omochi-socket
rm -f /etc/systemd/system/omochi-*.service
systemctl daemon-reload
```

### 1-2. omochi ユーザーの linger（ログアウト後も常駐）を有効化
ユーザーインスタンスのサービスが SSH 切断後も稼働し続けるために必須の設定です。
```bash
loginctl enable-linger omochi
```
※ `ls /var/lib/systemd/linger/omochi` が存在することを確認します。

一旦 root での作業は終了です。`exit` で抜けるか、`omochi` ユーザーに切り替えます。

---

## Step 2: ユーザーサービスの設定 & 起動（omochi ユーザーで作業）

```bash
su - omochi
```

### 2-1. 最新コードを取得
```bash
cd ~/omochi
git pull
```

### 2-2. ユーザー用 systemd ディレクトリの作成 & ユニット配置
```bash
mkdir -p ~/.config/systemd/user
cp config/deploy/systemd/user/*.service ~/.config/systemd/user/
```

### 2-3. ユーザーサービスを有効化 & 起動
```bash
systemctl --user daemon-reload
systemctl --user enable --now omochi-web omochi-worker omochi-socket
```

### 2-4. 稼働確認
```bash
systemctl --user status omochi-web omochi-worker omochi-socket
```
- `omochi-web` および `omochi-worker` が `active (running)` になっていることを確認します。
- ブラウザから `https://omochi.ummm.info` にアクセスし、正常に Dashboard が開くことを確認します。

---

## Step 3: 手動デプロイスクリプトの疎通確認（omochi ユーザーで作業）

新設した `bin/deploy` が単体で問題なく動作するか確認します。

```bash
cd ~/omochi
./bin/deploy
```
`=== [omochi deploy] Successfully deployed! ===` と表示されれば、サーバー側の移行は完全に完了です。

---

## Step 4: GitHub Actions 自動デプロイの設定（GitHub リポジトリ設定）

`main` ブランチに push されたときに GitHub Actions が自動で SSH 接続してデプロイできるよう、GitHub リポジトリの Secrets を設定します。

### 4-1. デプロイ用 SSH 鍵の準備
VPS の `omochi` ユーザーで、GitHub Actions からの SSH 接続専用の鍵ペアを作成します。
（既存の `~/.ssh/id_ed25519` を使っても構いませんが、CI 用に分けると管理が安全です）

```bash
# omochi ユーザーで実行
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_actions_deploy -N ""
cat ~/.ssh/github_actions_deploy.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

生成された **秘密鍵（private key）** の内容を表示します：
```bash
cat ~/.ssh/github_actions_deploy
```
（`-----BEGIN OPENSSH PRIVATE KEY-----` から `-----END OPENSSH PRIVATE KEY-----` までをコピー）

### 4-2. GitHub Secrets への登録
GitHub リポジトリの **Settings > Secrets and variables > Actions** を開き、以下の Repository secrets を追加します：

| Secret 名 | 値 | 説明 |
|---|---|---|
| `DEPLOY_HOST` | `133.18.115.252` | VPS の IP アドレス（または `omochi.ummm.info`） |
| `DEPLOY_USER` | `omochi` | SSH 接続ユーザー |
| `DEPLOY_SSH_KEY` | 先ほどコピーした秘密鍵の内容 | `github_actions_deploy` の秘密鍵テキスト |
| `DEPLOY_PORT` | `22` | SSH ポート（デフォルト 22） |

---

これで以後、手元から `git push origin main` を行うだけで：
1. GitHub Actions でテスト・静的解析が自動実行
2. テスト合格後、VPS に `omochi` ユーザーで SSH 接続し `bin/deploy` が自動実行
3. サービスが自動再起動して本番反映
という完全自動 CI/CD が稼働します。
