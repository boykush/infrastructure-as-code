# CLAUDE.md

boykush の個人アプリケーションを載せる Kubernetes 基盤の IaC リポジトリ。DOKS クラスタを Terraform（`digitalocean/digitalocean` provider）で、その上のアプリケーションを Argo CD で管理する。構成値と手順は README を見る。

## レイアウト

- `terraform/` — クラスタ本体（VPC + DOKS cluster + node pool）。root module は1つだけで、環境の分岐も tfvars も無い。`variables.tf` の default がそのまま live の設定。
- `kubernetes/` — Argo CD と各アプリの manifest（未着手）。

## Toolchain

- Terraform / doctl / kubectl は mise で固定（`mise.toml`）。セットアップは `mise install`、version 変更は `mise.toml` の編集だけ。
- `mise.lock` は一旦使わない（`settings.lockfile` 未設定 = false）。checksum まで固定するなら `lockfile = true` に戻し、`mise lock -p linux-x64,linux-arm64,macos-arm64,macos-x64` で全 platform 分を生成する。
- provider は `.terraform.lock.hcl` で固定（**commit する**）。`versions.tf` の `~> 2.0` は緩いので、実際に使う version を決めているのは lock file。更新は **全 platform を明示**して行う:
  ```sh
  mise exec -- terraform providers lock \
    -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64
  ```
- kubectl の pin はクラスタの minor に追従させる。`kubernetes_version_prefix` を上げたら `mise.toml` の kubectl も上げる（skew は ±1 minor まで）。

## Backend / 認証

- state は HCP Terraform（org `boykush` / workspace `infrastructure-as-code`）。Execution Mode = **Local**。remote のままだと HCP 側で実行され、DO token が無い環境で plan が落ちる（workspace 新規作成時の default は remote なので、作り直したら必ず変える）。
- provider の認証は `DIGITALOCEAN_ACCESS_TOKEN`。provider が優先して読むのは `DIGITALOCEAN_TOKEN` だが、doctl が読むのは `DIGITALOCEAN_ACCESS_TOKEN` だけなので、1変数で両方賄えるこちらに寄せている。
- CI は secret `TF_API_TOKEN`（HCP backend）と `DIGITALOCEAN_ACCESS_TOKEN`（provider）。tfcmt は built-in の `GITHUB_TOKEN` を使う——owner 全体の default workflow permissions が read に絞られているため、job の `permissions:` で `pull-requests: write` / `issues: write` を戻している。

## ワークフロー

- 変更は PR 経由。PR で `terraform plan`（tfcmt がコメント）、main への push で `terraform apply`。
- **ローカル apply はしない**。唯一の例外がクラスタの初回 bootstrap（CI の secret 登録より先にクラスタが要ったため）。
- CI の path filter は `terraform/**` と toolchain の pin だけ。`kubernetes/` の manifest は Terraform の plan と無関係（Argo CD が同期する）ので走らせない。

## DOKS の勘所

- **version と auto_upgrade**: `version` は `digitalocean_kubernetes_versions` data source が返す「pin した minor の最新 patch」。`auto_upgrade = true` なので patch 適用は DO がメンテナンス窓で行い、Terraform 側は追従するだけ。minor を上げる操作は `kubernetes_version_prefix` の編集。
- **新規作成できるのは最新3 minor だけ**（窓を過ぎた version は既存クラスタは動き続けるが新規作成不可）。現行は 1.34 / 1.35 / 1.36。手元での確認は `doctl kubernetes options versions`。
- **kubeconfig**: Terraform の `kube_config` に入る token は 7 日で失効するので output していない。`mise run k8s:kubeconfig`（doctl）で取ると、doctl 経由で再認証する context になる。
- **surge_upgrade**: 1ノード構成なので、upgrade 中に pod の退避先が無くならないよう有効にしている。その間だけノードが1台増え、その分は課金される。
- **destroy**: `destroy_all_associated_resources = true`。`type: LoadBalancer` の Service や PVC が作った LB / volume はクラスタとは別課金で、これが無いと destroy 後も残って課金され続ける。
- **置換系の変更に注意**: VPC の `ip_range` は作成後変更不可（変えると VPC 置換 → クラスタも置換）。cluster の `region` / node pool の `name` も同様。
- `prevent_destroy` は**あえて付けていない**。中身は GitOps で作り直せるので、使わない期間に `terraform destroy` で課金を止められる方を優先した。
