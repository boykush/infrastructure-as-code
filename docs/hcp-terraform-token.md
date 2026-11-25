# HCP Terraform の API token

CI の Terraform は、state と lock を HCP Terraform（app.terraform.io）に置いている。そこへ入るための API token は
期限付きで、切れると `terraform init` が次のエラーで止まる。この repo の Terraform の job がすべて赤くなる。

```
Error: Failed to read organization "boykush" at host app.terraform.io
Encountered an unexpected error while reading the organization settings: unauthorized
```

token は repo ごとに分け、AWS の Parameter Store に `/hcp-terraform/<repo>` として置く。workflow が自分の repo の分を
読み、`TF_TOKEN_app_terraform_io` として渡す。どの repo が読めるかは `terraform/aws.tf` と
`terraform/variables.tf` の `hcp_terraform_repositories` が持つ。

期限の 30 日前と 7 日前に、HCP Terraform から通知のメールが来る。期限は作った後から延ばせないので、入れ替えは
新しい token を作ることになる。

## 1. 発行する

使うのは、`owners` team の **Team token**（owner と同じ権限を持つ）。Organization token は state の読み書き
（plan・apply）ができないので使えない。

1. HCP Terraform の Organization `boykush` で、**Settings → API tokens → Team Tokens** タブを開く。
2. `owners` team の token を新しく作る。
   - **Description は必ず付ける**（例: `infrastructure-as-code CI`）。Description の無い token は legacy token
     として扱われ、team に1つしか持てない。新しく legacy token を作ると、前の legacy token が無効になる。
   - 期限（Expiration）を付ける。
3. 表示された値をコピーする。**値は作成時の1回しか表示されない。**

## 2. Parameter Store に書く

先に AWS へログインする（ブラウザが開き、パスキーで通る）。

```sh
mise exec -- aws login
mise exec -- aws sts get-caller-identity   # account id が返れば通っている
```

値は端末に表示させず、プロンプトに貼り付けて Ctrl-D で入れる。`<repo>` は token を使う repo の名前。

```sh
mise run hcp:token <repo>
```

## 3. 確かめる

- その repo の開いている PR で、Terraform の job を re-run する。`terraform init` と plan が通ればよい。
- 通ったら、Team Tokens タブで古い token を消す（期限切れのものは、Filters で expired を選ぶと見つかる）。
