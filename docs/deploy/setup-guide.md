# omochi 本番サーバー構築 & デプロイ手順書

- **対象環境**: KAGOYA CLOUD VPS (Ubuntu 24.04 LTS, 4GB)
- **IP アドレス**: `133.18.115.252`
- **公開ドメイン**: `https://omochi.ummm.info`
- **プロセス管理**: Systemd User Services (`systemctl --user`)

---

## 1. サーバーの初期設定（root で作業）

まずは SSH で VPS にログインします。

```bash
ssh root@133.18.115.252
```

### パッケージの更新 & 必要なツールのインストール
```bash
apt update && apt upgrade -y
apt install -y curl git build-essential libssl-dev libyaml-dev libreadline-dev \
               zlib1g-dev libncurses5-dev libffi-dev libgdbm-dev pkg-config \
               libsqlite3-dev sqlite3 apache2-utils certbot python3-certbot-nginx nginx
```

### Docker CE のインストール（公式スクリプト）
```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

### 実行ユーザー `omochi` の作成 & linger（ユーザー常駐）有効化
```bash
# ユーザー作成 & docker グループ追加
adduser --disabled-password --gecos "" omochi
usermod -aG docker omochi

# ユーザーサービス（systemctl --user）をログアウト後も常駐させる設定
loginctl enable-linger omochi

# データ永続化ディレクトリの作成
mkdir -p /var/lib/omochi/storage /var/lib/omochi/workspaces
chown -R omochi:omochi /var/lib/omochi
```

---

## 2. アプリケーション実行環境の構築（omochi ユーザーで作業）

```bash
su - omochi
```

### Deploy Key の生成（プライベートリポジトリから clone する場合）
```bash
ssh-keygen -t ed25519 -C "omochi-vps-deploy-key" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
# 出力された公開鍵を GitHub の Repository Settings > Deploy keys に Read-only で登録
```

### Ruby 4.0.6 のインストール（mise を使用）
```bash
curl https://mise.run | sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
eval "$($HOME/.local/bin/mise activate bash)"

# Ruby 4.0.6 のビルド & グローバル指定
mise use -g ruby@4.0.6
ruby -v  # ruby 4.0.6 が表示されることを確認
```

### Agent 用 Docker イメージのプル
コンテナ実行時に即時起動できるよう、事前にイメージを pull しておきます。
```bash
docker pull ruby:4.0
```

### ソースコードの配置 & 依存関係の導入
```bash
cd ~
git clone git@github.com:hamajyotan/omochi.git
cd omochi

bundle config set --local deployment 'true'
bundle config set --local without 'development test'
bundle install
```

### 本番環境変数（`.env`）の作成
手元の `config/master.key` の値をコピーして設定します。

```bash
cat << 'EOF' > /var/lib/omochi/.env
RAILS_ENV=production
RAILS_MASTER_KEY=<ここに config/master.key の値を入力>

PORT=3000
OMOCHI_STORAGE_DIR=/var/lib/omochi/storage
OMOCHI_WORKSPACES_DIR=/var/lib/omochi/workspaces
JOB_CONCURRENCY=1

# Slack 連携を行う場合は記入（空の場合は Socket Mode はスキップされます）
SLACK_BOT_TOKEN=
SLACK_APP_TOKEN=
EOF

chmod 600 /var/lib/omochi/.env
ln -s /var/lib/omochi/.env ~/omochi/.env
```

### データベース準備 & アセットコンパイル
```bash
set -a; source /var/lib/omochi/.env; set +a
bin/rails db:prepare
bin/rails assets:precompile
```

---

## 3. Systemd ユーザーサービスの設定（omochi ユーザーで作業）

root 権限不要の `systemctl --user` でプロセスを常駐化します。

```bash
mkdir -p ~/.config/systemd/user
cp ~/omochi/config/deploy/systemd/user/*.service ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now omochi-web omochi-worker omochi-socket
```

サービスの状態を確認：
```bash
systemctl --user status omochi-web omochi-worker omochi-socket
```

一旦 `exit` して `root` ユーザーに戻ります。
```bash
exit
```

---

## 4. Nginx（リバースプロキシ・Basic認証・SSL）の設定（root で作業）

### Basic 認証ユーザーの作成
```bash
htpasswd -c /etc/nginx/.htpasswd admin
# パスワードを入力
```

### Nginx 設定ファイルの配置
```bash
cat << 'EOF' > /etc/nginx/sites-available/omochi
server {
    server_name omochi.ummm.info;

    auth_basic "omochi Dashboard";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Action Cable (WebSockets) サポート
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

ln -s /etc/nginx/sites-available/omochi /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

### Let's Encrypt による SSL/TLS 証明書の取得
```bash
certbot --nginx -d omochi.ummm.info
```

---

## 5. 以後のデプロイ（手動または自動）

### 手動デプロイ（omochi ユーザーで実行）
```bash
~/omochi/bin/deploy
```

### GitHub Actions による自動デプロイ
`main` ブランチに push すると自動的にテストが実行され、合格後に VPS へデプロイされます。
設定手順の詳細は [migration-to-user-systemd.md](migration-to-user-systemd.md) の Step 4 を参照してください。
