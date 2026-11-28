# /secrets/hcp-terraform/owners

HCP Terraform の `owners` team の Team token。infrastructure-as-code と github-management の Terraform が、state と lock
（app.terraform.io）に入るのに使う。両 repo が同じ token を読むので、切れると両方の Terraform の job が
`terraform init` で止まる。

```
Error: Failed to read organization "boykush" at host app.terraform.io
Encountered an unexpected error while reading the organization settings: unauthorized
```

期限の 30 日前と 7 日前に、HCP Terraform から通知のメールが来る。期限は作った後から延ばせないので、入れ替えは
新しい token を作ることになる。

## 発行する

使うのは `owners` team の **Team token**（owner と同じ権限を持つ）。Organization token は state の読み書き
（plan・apply）ができないので使えない。

1. <https://app.terraform.io/app/boykush/settings> の **API Tokens → Team Tokens** タブを開く。
2. **Create a team token** で、Team は `owners`。
   - Description: `hcp-terraform-owners-team-token`（この Resource の name）。**必ず付ける**——Description の無い
     token は legacy token として扱われ、team に1つしか持てず、新しく作ると前のものが無効になる。
   - 期限（Expiration）を付ける。
3. 値は作成時の1回しか表示されない。画面を閉じる前に、次の手順で書く。

## 書く

infrastructure-as-code の checkout で、AWS にログインしてから書く。値はプロンプトに貼り付けて Ctrl-D。

```sh
mise exec -- aws login
mise run secret:write hcp-terraform/owners
```

## 確かめる

- infrastructure-as-code と github-management の開いている PR で、Terraform の job を re-run する。`terraform init`
  と plan が通ればよい。
- 通ったら、Team Tokens タブで古い token を消す（期限切れのものは、Filters で expired を選ぶと見つかる）。

## 誰が読むか

[`terraform/aws.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/aws.tf) の
`local.terraform_secrets` と、[`terraform/variables.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/variables.tf)
の `secret_readers` が持つ。
