---
name: recover-ci-role
description: CI が apply に使う AWS の role を手元から作り直す。この repo で唯一ローカルの apply が要る場面。「CI の terraform が AssumeRoleWithWebIdentity で落ちる」「role の信頼や権限を壊した」「AWS の account を作り直した」ときに使う。
---

# CI の role を手元から直す

CI は Terraform 自身が作る role（`github-actions-terraform`、`terraform/aws.tf`）を assume して apply する。その role を壊す変更が merge されると CI では直せないので、**role だけを手元から apply し、残りは CI に任せる**。最初に role を作ったとき（2026-09-23）と同じ手順。

## 1. AWS にログインしてもらう

人間に頼む。root にパスキーの MFA が付いている。**access key は作らない**——root のものは AWS が禁じているし、IAM ユーザーのものも要らない。

```sh
mise exec -- aws login
```

`aws login` はコンソールのサインインから最大12時間の一時認証情報を取る（CLI 2.32.0 以降）。Identity Center・Organizations・access key のどれも要らない。

- **profile とリージョンは repo に閉じている。** `mise.toml` の `[env]` が `AWS_CONFIG_FILE` を `.aws/config` に、`AWS_REGION` を `ap-northeast-1` に向けているので、`~/.aws/config` には何も書かれない。`.aws/` は commit しない。
- **profile 名は `default` のまま。** `AWS_PROFILE` を `[env]` に置くと、`.aws/config` の無い runner で CI の terraform が `failed to get shared config profile` で落ちる。
- **AWS の認証情報を export しない。** aws provider は `login_session` をそのまま解釈する。`aws configure export-credentials` が返すのは15分で切れる認証情報で、env は profile より優先されるので、切れた後の復旧の邪魔になる。
- **Identity Center は使っていない。** 単一 account で有効化すると account instance になり、permission set も account の割り当ても持てないので、CLI の認証情報が出てこない。

```sh
mise exec -- aws sts get-caller-identity
```

`509266991346` が返れば通っている。

## 2. 宣言済みの変数に値を渡す

root module は1つなので、AWS だけ apply するときも宣言済みの変数に値が要る。**実値を入れてもらう**——この手順では使われないが、同じシェルで後から full apply すると Access がその値で書き換わる。

```sh
export TF_VAR_access_owner_email=...
export TF_VAR_access_github_client_secret=...
```

## 3. role だけを apply する

**DO と Cloudflare の認証情報は要らない。** 次の resource はどちらにも依存していないので、`-target` で絞ればそれらの API は呼ばれず、refresh も走らない。素の `apply` は state 全体を触りにいくので使わない。

```sh
mise exec -- terraform -chdir=terraform apply \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_role.terraform \
  -target=aws_iam_role_policy.terraform
```

plan が直したい差分だけになっているのを確かめてから `yes`。`-target` には「通常運用向けではない」という警告が出るが、これがその例外。**残りは CI の次の apply が揃える。** account を作り直したときは、Claude Code のトークンを読む role（`aws_iam_role.claude_code`、`aws_iam_role_policy.claude_code`）も足し、その後でトークンを入れる（skill `rotate-credential`）。

## 4. ログアウトしてもらう

```sh
mise exec -- aws logout
```

長命の鍵をどこにも作っていないので、消すものは無い。

## 確かめる

- 直す変更を載せた PR の `terraform plan` が通ること。merge 後の push で CI が `github-actions-terraform` として full apply する。権限の過不足が出るならそこで、`iam:*` は名指しの ARN に絞ってあるので、resource 指定を受け付けない IAM アクションがあれば `AccessDenied` で分かる。
- role の ARN は `.github/workflows/terraform.yml` と boykush/workflows の `.github/actions/claude-code-token/action.yml` に直接書いてある。role 名を変えたなら両方を直す。
