---
name: rotate-credential
description: 資格情報を入れる・入れ替える。Claude Code のトークン、CI の token（DO・Cloudflare・HCP）、クラスタの Secret に入る値（tunnel token・R2 token・Image Updater の App）、External Secrets Operator の access key、Access の GitHub ログイン。「トークンの期限が切れる」「漏れたかもしれない」「Secret を入れる」「tunnel を作り直した」「CreateContainerConfigError」ときに使う。
---

# 資格情報を入れる・入れ替える

## 前提

- 何を人間が発行し、どこに置くかは `docs/credentials.md`。値の発行（GUI・`claude setup-token`）だけは人間に頼む。それ以外はここに沿って進める。
- AWS に書くものは、先に `mise exec -- aws login` を頼む（ブラウザが開いてパスキーで通る）。`mise exec -- aws sts get-caller-identity` が account id を返せば通っている。
- **値を Terraform に通さない**（state に平文が載る）。書くのは mise の task だけ。
- 値を端末に出さない。貼ってもらうときは stdin に貼って Ctrl-D。

## クラスタの Secret に値を入れる

値は Parameter Store に書き、External Secrets Operator がクラスタの Secret に同期する。**どの parameter がどの Secret になるかは、使う app の隣の `ExternalSecret` が持つ。**

```sh
mise run cluster:secret <namespace> <secret> <key>   # 値を貼って Ctrl-D
```

- 反映は `ExternalSecret` の `refreshInterval` ごと。Secret を env で読む Pod は、再起動するまで古い値のまま動く（`kubectl -n <ns> rollout restart deployment/<name>`）。
- Secret ができるまで、それを読む Pod は `CreateContainerConfigError` で止まる。
- Secret を増やすときは、app の directory に `ExternalSecret` を足し、同じ名前の parameter を書く。operator が読めるのは `terraform/variables.tf` の `cluster_secrets_parameter_path` の下だけ。

### tunnel token

tunnel を作り直したときだけ。値は Terraform の output から取る（`tf:login` 済みであること）。

```sh
mise exec -- terraform -chdir=terraform output -raw tunnel_token \
  | mise run cluster:secret cloudflared cloudflared-tunnel-token token
```

### finlake の R2 token

人間に頼む：ダッシュボードの R2 → Manage API tokens で、権限 Object Read & Write、対象をバケット `finlake` だけに絞って作る。出てくる Access Key ID / Secret Access Key と、S3 のエンドポイント（`https://` を除いた `<account_id>.r2.cloudflarestorage.com`）を受け取る。account id は git のどこにも無い（Terraform が domain から引く）ので、エンドポイントも Secret に置いている。

```sh
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_ENDPOINT
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_ACCESS_KEY_ID
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_SECRET_ACCESS_KEY
mise exec -- kubectl -n finlake rollout restart deployment/mcp
```

`sync` の CronJob と `mcp` が同じ Secret を読む。古い token は、両方が新しい値で動いてからダッシュボードで消す。

### TechDocs の R2 token

token は2つ。publish する CI 用と、Backstage が読む用で、置き場も別。人間に頼む：ダッシュボードの R2 → Manage API tokens で、対象をバケット `techdocs` だけに絞って、権限 Object Read & Write のもの（publish 用）と Object Read only のもの（Backstage 用）を作る。それぞれの Access Key ID / Secret Access Key と、S3 のエンドポイント（`https://` を除いた `<account_id>.r2.cloudflarestorage.com`）を受け取る。

publish 用は Parameter Store の `/techdocs/*` に置き、各 repo の workflow が role `github-actions-techdocs` で読む。クラスタには入れない。

```sh
mise run techdocs:secret endpoint
mise run techdocs:secret access-key-id
mise run techdocs:secret secret-access-key
```

Backstage 用はクラスタの Secret に入れる。Secret は optional で読んでいるので、無くても Backstage は起動し、Docs タブだけが開かない。

```sh
mise run cluster:secret backstage techdocs-r2 TECHDOCS_S3_ENDPOINT
mise run cluster:secret backstage techdocs-r2 TECHDOCS_S3_ACCESS_KEY_ID
mise run cluster:secret backstage techdocs-r2 TECHDOCS_S3_SECRET_ACCESS_KEY
mise exec -- kubectl -n backstage rollout restart deployment/backstage
```

publish 用を入れ替えたら、どれかの repo の TechDocs workflow を `gh workflow run techdocs.yml` で流して通ることを確かめてから、古い token を消す。

### Image Updater の GitHub App

Image Updater の git write-back には main への push 権限が要る。**PAT では通らない**——main の ruleset（`boykush/github-management` が張る Require pull request と required check）を bypass できるのは GitHub App だけ。App の id は github-management の ruleset module の bypass actor にも載っている必要がある。App に要る権限は Contents: write、install 先はこの repo だけ。

この App の鍵だけは KMS に入れない（Image Updater がクラスタの中で自分で JWT に署名するので、鍵そのものが要る）。**PEM も GitHub には置かない。**

```sh
echo <App ID> | mise run cluster:secret argocd image-updater-git-creds githubAppID
echo <Installation ID> | mise run cluster:secret argocd image-updater-git-creds githubAppInstallationID
mise run cluster:secret argocd image-updater-git-creds githubAppPrivateKey < <app>.private-key.pem
```

- `githubAppID` は **App ID（数値）**。Image Updater は base 10 で parse するので、Client ID を入れると `invalid value in field githubAppID` で落ちる。
- 鍵を入れ替えるときは、App に新しい鍵を足す → 入れる → 反映を確かめる → 古い鍵を App から revoke、の順なら止まる時間ができない。入れ終えたら手元の PEM を消してもらう。
- Secret が無いと、Image Updater は Pod が落ちないまま `could not get creds for repo` をログに出し続ける。digest が動かないときは、まずここを見る。

## Claude Code のトークン

有効期間は1年。期限が近いとき、漏れたかもしれないときに入れ替える。

1. 人間に `claude setup-token` を実行してもらい、出力を受け取る。
2. 貼ってもらう。端末幅で折り返された値には改行が混ざるので、task が空白を落とし、`sk-ant-oat` で始まるかを確かめている。

```sh
mise run claude:token
mise exec -- aws ssm get-parameter --region ap-northeast-1 --name /claude-code/oauth-token \
  --query 'Parameter.{Version:Version,Type:Type}'
```

確かめるのは version が上がったことだけで、値は出さない。読む側の repo は何も触らなくていい。経路全体が通ったかは、トークンを読む workflow（ai-review を入れた repo の PR の review）が次に動いたときにしか分からない。

## CI の token（DO・Cloudflare・HCP）

人間に頼む：各コンソールで発行し直す。要る権限は `terraform/providers.tf` のコメント（DO・Cloudflare）にある。そのうえで値を repo secret に入れる。

```sh
gh secret set DIGITALOCEAN_ACCESS_TOKEN
gh secret set CLOUDFLARE_API_TOKEN
gh secret set TF_API_TOKEN
```

- Cloudflare は、既存の token の期限や権限を編集するだけなら値は変わらないはず。その場合は secret を触らず、次の plan が通るかで確かめる。
- DO の PAT を替えたら、手元の `doctl auth init` もやり直してもらう。
- 入れた後、PR の `terraform plan` が通ることと、夜間停止の次の run が通ることを確かめる。DO の PAT が切れると resume が失敗し、クラスタが止まったまま戻らない。

## External Secrets Operator の access key

AWS に残る唯一の長命な鍵。入れ替えるときも、クラスタを作り直したときも同じ。作り直しなら2行目だけでいい。

```sh
mise run external-secrets:key
gh workflow run external-secrets-credential.yml
```

`external-secrets:key` は古い鍵を消してから新しい鍵を作る。workflow が届けるまで operator は同期できないが、クラスタにある Secret はそのまま残るので、止まるのは更新だけ。

## Access の GitHub ログイン

Backstage・Argo CD・Headlamp・Jaeger と非公開の MCP の前段にある Access は、owner の OAuth App で GitHub ログインする。GitHub には OAuth App を作る API が無いので、人間に頼む。

- 作り方：Settings → Developer settings → OAuth Apps。Homepage URL は `https://boykush-zt.cloudflareaccess.com`、Authorization callback URL は `https://boykush-zt.cloudflareaccess.com/cdn-cgi/access/callback`。Client ID は `terraform/access.tf` に書き、Client secret は repo secret `ACCESS_GITHUB_CLIENT_SECRET`（CI が `TF_VAR_access_github_client_secret` で渡す）。
- Client secret を替えるとき：OAuth App に新しい secret を足し、`ACCESS_GITHUB_CLIENT_SECRET` を差し替え、次の apply で Cloudflare に届いてから古い方を消す。
- 通すメールアドレスは repo secret `ACCESS_OWNER_EMAIL`（public repo に置かない）。照合相手は GitHub がログインしたアカウントについて返すアドレスで、Zero Trust ダッシュボードの GitHub のログイン方法で Test を押すと見られる。
