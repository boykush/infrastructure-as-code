# HCP Terraform の API token

CI の Terraform は、state と lock を HCP Terraform（app.terraform.io）に置いている。そこへ入るための API token は
期限付きで、切れると `terraform init` が次のエラーで止まる。この repo の Terraform の job がすべて赤くなる。

```
Error: Failed to read organization "boykush" at host app.terraform.io
Encountered an unexpected error while reading the organization settings: unauthorized
```

token は repo secret `TF_API_TOKEN` に置き、workflow（`.github/workflows/terraform.yml`）が
`TF_TOKEN_app_terraform_io` として渡す。AWS（Parameter Store）には置いていない。

## 1. 今の token を見つける

HCP Terraform にログインし、期限の切れた token を探す。種類によって一覧のある場所が違う。

- **User token**: 右上のアイコン → Account settings → Tokens
- **Team token**: Organization `boykush` → Settings → Teams → 該当の team → Team API Token
- **Organization token**: Organization `boykush` → Settings → API tokens

見つかった種類で作り直す。種類を変えると、state を読めるかどうかの権限も変わる。

## 2. 発行する

1. 見つけた場所で token を新しく作る（Create / Generate）。期限（Expiration）を付けられる場合は付ける。
2. Description には、どこで使う token か（例: `infrastructure-as-code CI`）を書く。次に切れたとき、どれを替えるかがここで分かる。
3. 表示された値をコピーする。**値は作成時の1回しか表示されない。** 画面を閉じる前に、次の手順で secret に入れる。

## 3. repo secret に入れる

値は端末に表示させず、プロンプトに貼り付けて Enter（または Ctrl-D）で入れる。

```sh
gh secret set TF_API_TOKEN -R boykush/infrastructure-as-code
```

## 4. 確かめる

- 開いている PR の Terraform の job を re-run して、`terraform init` と plan が通ることを確かめる。
- 通ったら、HCP Terraform で古い token を消す（Revoke / Delete）。期限切れのものも、一覧に残すと次にどれを替えるか迷う。

## 他の repo との関係

boykush/github-management も、同じ HCP Terraform の organization に state を置き、自分の repo secret `TF_API_TOKEN` を持つ。
同じ token を両方に入れている場合は、片方が切れるともう片方も同じ時に切れる。手順 1 の一覧で、もう片方の期限も見ておく。
