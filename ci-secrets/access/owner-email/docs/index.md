# /ci-secrets/access/owner-email

Cloudflare Access が通すメールアドレス。資格情報ではなく個人情報なので、public repo に置かずここに置く。どこかで
発行するものではなく、期限も無い。

## 照合される値を確かめる

照合相手は、GitHub がログインしたアカウントについて返すアドレス。<https://one.dash.cloudflare.com/> の
Zero Trust ダッシュボードで、GitHub のログイン方法の **Test** を押すと見られる。

## 書く

```sh
mise exec -- aws login
mise run ci:secret access/owner-email   # アドレスを貼って Ctrl-D
```

Access に届くのは次の apply。apply は `terraform/` を変える PR が main に入ったときにだけ走る。

## 誰が読むか

[`terraform/aws.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/aws.tf) の
`local.terraform_ci_secrets` が持つ。
