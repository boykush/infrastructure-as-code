# /ci-secrets/cloudflare/infrastructure-as-code

Cloudflare の Account API token。Terraform の provider が読む（Tunnel・DNS・Access・R2）。切れると Terraform の
plan が `data.cloudflare_zones.this` の `403 Invalid access token` で止まる。

## 期限が切れそうなとき

<https://dash.cloudflare.com/?to=/:account/api-tokens>（Account API tokens）で `infrastructure-as-code` の
`…` → **Edit** から TTL を延ばす。値は変わらないので、書き直さなくていい。次の plan が通るかで確かめる。

## 作り直す

1. 同じ画面で `infrastructure-as-code` の `…` → **Roll**。権限はそのまま、値だけが新しくなる。
   token ごと作り直すときは **Create token** で、権限は
   [`terraform/providers.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/providers.tf)
   の `provider "cloudflare"` のコメントのとおりにする。名前は `infrastructure-as-code`。
2. 値は1回しか表示されない。画面を閉じる前に書く。

```sh
mise exec -- aws login
mise run ci:secret cloudflare/infrastructure-as-code   # 値を貼って Ctrl-D
```

3. 開いている PR の Terraform の job を re-run して、plan が通ることを確かめる。

## 誰が読むか

[`terraform/aws.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/aws.tf) の
`local.terraform_ci_secrets` が持つ。
