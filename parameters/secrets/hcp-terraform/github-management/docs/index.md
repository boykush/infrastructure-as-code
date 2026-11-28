# /secrets/hcp-terraform/github-management

github-management の Terraform が HCP Terraform の state と lock に入るための token。切れると、
github-management の Terraform の job がすべて `terraform init` で止まる。

## 入れ替える

発行から確かめるまでの手順は、HCP Terraform の token に共通の
[HCP Terraform の API token](https://backstage.boykush.com/docs/default/component/infrastructure-as-code/hcp-terraform-token/)
にある。この鍵に固有なのは次の 2 つだけ。

- Description: `hcp-terraform-github-management-team-token`（この Resource の name）
- 書く: `mise run secret:write hcp-terraform/github-management`（infrastructure-as-code の checkout で）

確かめるのは、github-management の開いている PR の Terraform の job。

## 誰が読むか

[`terraform/variables.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/variables.tf) の
`secret_readers` が持つ。
