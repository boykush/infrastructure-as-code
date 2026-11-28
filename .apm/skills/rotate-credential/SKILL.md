---
name: rotate-credential
description: 資格情報を入れる・入れ替える。Claude Code のトークン、CI の token（DO・Cloudflare・HCP）、クラスタの Secret に入る値（tunnel token・R2 token・Image Updater の App）、External Secrets Operator の access key、Access の GitHub ログイン。「トークンの期限が切れる」「漏れたかもしれない」「Secret を入れる」「tunnel を作り直した」「CreateContainerConfigError」ときに使う。
---

# 資格情報を入れる・入れ替える

## 前提

- 値の発行（GUI・`claude setup-token`）だけは人間に頼む。それ以外はここに沿って進める。期限が来るたびに発行し直すのは下の表のもの。期限の日付は各コンソールが表示しているので、どこにも書かない。

  | 値 | 発行する場所 | 置き場 | 要る権限 |
  | --- | --- | --- | --- |
  | Claude Code のトークン | 鍵ごとの TechDocs（下の「Parameter Store の鍵」） | Parameter Store | — |
  | DO の PAT | DO のコントロールパネル | repo secret `DIGITALOCEAN_ACCESS_TOKEN` | `terraform/providers.tf` のコメント |
  | Cloudflare の API token | Cloudflare のダッシュボード | repo secret `CLOUDFLARE_API_TOKEN` | `terraform/providers.tf` のコメント |
  | HCP Terraform の API token（全 repo 共通） | 鍵ごとの TechDocs（下の「Parameter Store の鍵」） | Parameter Store（`/secrets/hcp-terraform/owners`） | — |
  | finlake の R2 token | 鍵ごとの TechDocs（下の「Parameter Store の鍵」） | Parameter Store | 鍵ごとの TechDocs |

- 期限の無いもの（GitHub App の鍵、Access のログインに使う OAuth App の Client secret、tunnel token、External Secrets Operator の access key）は、漏れたときと元を作り直したときだけ入れ替える。
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

## Parameter Store の鍵

Parameter Store の parameter は1件ずつ catalog の Resource（type `ssm-parameter`、title が parameter のパス）になっていて、その TechDocs が人向けの手順——何の値か、発行する場所、入れ方、確かめ方、古い値の消し方——を持つ。実体は `parameters/<パスの先頭の / を除いたもの>/docs/index.md`。入れ替えるときはそのページを読んで進め、人には Backstage のそのページを渡す。

- parameter を増やす・消すときは、`catalog-info.yaml` の Resource と `parameters/` の TechDocs も足す・消す。
- Image Updater の App は **PAT で代えられない**——main の ruleset（`boykush/github-management` が張る）を bypass できるのは GitHub App だけで、App の id は github-management の ruleset module の bypass actor にも載っている必要がある。App に要る権限は Contents: write、install 先はこの repo だけ。

## CI の token（DO・Cloudflare・HCP）

人間に頼む：各コンソールで発行し直す。要る権限は `terraform/providers.tf` のコメント（DO・Cloudflare）にある。DO と Cloudflare は値を repo secret に入れる。

```sh
gh secret set DIGITALOCEAN_ACCESS_TOKEN
gh secret set CLOUDFLARE_API_TOKEN
```

HCP の token は全 repo で1本で、Parameter Store の `/secrets/hcp-terraform/owners` にあり、手順は上の「Parameter Store の鍵」のとおり鍵ごとの TechDocs が持つ。値は `mise run secret:write hcp-terraform/owners` で書く。どの workflow が読めるかは `terraform/aws.tf` の `local.terraform_secrets` と `var.secret_readers` が持つ。

- Cloudflare は、既存の token の期限や権限を編集するだけなら値は変わらないはず。その場合は secret を触らず、次の plan が通るかで確かめる。
- DO の PAT を替えたら、手元の `doctl auth init` もやり直してもらう。
- 入れた後、PR の `terraform plan` が通ることと、夜間停止の次の run が通ることを確かめる。DO の PAT が切れると resume が失敗し、クラスタが止まったまま戻らない。

## Access の GitHub ログイン

Backstage・Argo CD・Jaeger と非公開の MCP の前段にある Access は、owner の OAuth App で GitHub ログインする。GitHub には OAuth App を作る API が無いので、人間に頼む。

- 作り方：Settings → Developer settings → OAuth Apps。Homepage URL は `https://boykush-zt.cloudflareaccess.com`、Authorization callback URL は `https://boykush-zt.cloudflareaccess.com/cdn-cgi/access/callback`。Client ID は `terraform/access.tf` に書き、Client secret は repo secret `ACCESS_GITHUB_CLIENT_SECRET`（CI が `TF_VAR_access_github_client_secret` で渡す）。
- Client secret を替えるとき：OAuth App に新しい secret を足し、`ACCESS_GITHUB_CLIENT_SECRET` を差し替え、次の apply で Cloudflare に届いてから古い方を消す。
- 通すメールアドレスは repo secret `ACCESS_OWNER_EMAIL`（public repo に置かない）。照合相手は GitHub がログインしたアカウントについて返すアドレスで、Zero Trust ダッシュボードの GitHub のログイン方法で Test を押すと見られる。
