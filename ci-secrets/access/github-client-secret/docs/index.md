# /ci-secrets/access/github-client-secret

Cloudflare Access の GitHub ログインに使う OAuth App の Client secret。Terraform が Access の identity provider
に渡す。期限は無く、入れ替えるのは漏れたときと OAuth App を作り直したときだけ。

## 入れ替える

1. <https://github.com/settings/developers> → OAuth Apps で、Authorization callback URL が
   `https://boykush-zt.cloudflareaccess.com/cdn-cgi/access/callback` の App を開く。
2. **Generate a new client secret**。古い secret はまだ消さない。
3. 値は1回しか表示されない。画面を閉じる前に書く。

```sh
mise exec -- aws login
mise run ci:secret access/github-client-secret   # 値を貼って Ctrl-D
```

4. Cloudflare に届くのは次の apply。apply は `terraform/` を変える PR が main に入ったときにだけ走る。
5. 届いたら、Access の内側（Backstage など）に GitHub でログインできることを確かめ、OAuth App から古い secret を消す。

OAuth App そのものを作るときは、skill `rotate-credential` の「Access の GitHub ログイン」。

## 誰が読むか

[`terraform/aws.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/aws.tf) の
`local.terraform_ci_secrets` が持つ。
