# /ci-secrets/digitalocean/infrastructure-as-code

DigitalOcean の PAT。Terraform の provider と doctl が読む。切れると Terraform が止まるうえ、夜間の Node Pool
Park / Resume も失敗する——Resume が落ちるとクラスタは止まったまま朝に戻らない。

## 発行する

1. <https://cloud.digitalocean.com/account/api/tokens> で **Generate New Token**。
2. Token name: `infrastructure-as-code`
3. Expiration を付ける。
4. Scopes は **Custom Scopes** で、
   [`terraform/providers.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/providers.tf)
   の `provider "digitalocean"` のコメントにあるものを選ぶ。
5. 値は作成時の1回しか表示されない。画面を閉じる前に、次の手順で書く。

## 書く

```sh
mise exec -- aws login
mise run ci:secret digitalocean/infrastructure-as-code   # 値を貼って Ctrl-D
```

## 確かめる

- 開いている PR の Terraform の job を re-run して、plan が通る。
- `gh workflow run node-pool-status.yml -R boykush/infrastructure-as-code` が通る。

通ったら、DO のコントロールパネルで古い token を消す。

## 誰が読むか

[`terraform/aws.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/aws.tf) の
`local.terraform_ci_secrets`、[`terraform/variables.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/variables.tf)
の `ci_secret_readers`、`aws.tf` の External Secrets Credential の policy が持つ。
