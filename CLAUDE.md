# CLAUDE.md

boykush の個人アプリケーションを載せる Kubernetes 基盤の IaC リポジトリ。DOKS クラスタを Terraform（`digitalocean/digitalocean` provider）で、その上のアプリケーションを Argo CD で管理する。構成値と手順は README を見る。

## レイアウト

- `terraform/` — クラスタ本体（VPC + DOKS cluster + node pool）。root module は1つだけで、環境の分岐も tfvars も無い。`variables.tf` の default がそのまま live の設定。
- `argocd/` — Argo CD 本体 + Image Updater。kustomize の remote base を tag で固定している。
- `applications/` — アプリごとに `<name>.yaml`（Argo CD の Application）と `<name>/`（その manifest）を並べる。イメージのビルドは各アプリの repo が行い、ここにはその成果物を指す manifest だけが載る。

## Toolchain

- Terraform / doctl / kubectl は mise で固定（`mise.toml`）。セットアップは `mise install`、version 変更は `mise.toml` の編集だけ。
- `mise.lock` は一旦使わない。グローバル（`~/.config/mise/config.toml`）が `lockfile = true` なので、`mise.toml` で**明示的に `lockfile = false`** を置いて上書きしている——ファイルを消すだけでは次の mise コマンドで再生成される。checksum まで固定するなら `true` に戻し、`mise lock -p linux-x64,linux-arm64,macos-arm64,macos-x64` で全 platform 分を生成する。
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
- 残作業・TODO は **Issue で管理する**。README に書くのは現状の構成と手順だけで、作業項目のリストは置かない。
- **repo は public**。cluster の UUID と API endpoint が PR コメントに出ないよう、`cluster_id` / `cluster_endpoint` の output は `sensitive = true` にしてある（手元では `terraform output -raw cluster_endpoint` で読める）。
- CI の path filter は `terraform/**` と toolchain の pin だけ。`kubernetes/` の manifest は Terraform の plan と無関係（Argo CD が同期する）ので走らせない。

## DOKS の勘所

- **version と auto_upgrade**: `version` は `digitalocean_kubernetes_versions` data source が返す「pin した minor の最新 patch」。`auto_upgrade = true` なので patch 適用は DO がメンテナンス窓で行い、Terraform 側は追従するだけ。minor を上げる操作は `kubernetes_version_prefix` の編集。
- **新規作成できるのは最新3 minor だけ**（窓を過ぎた version は既存クラスタは動き続けるが新規作成不可）。現行は 1.34 / 1.35 / 1.36。手元での確認は `doctl kubernetes options versions`。
- **kubeconfig**: Terraform の `kube_config` に入る token は 7 日で失効するので output していない。`mise run k8s:kubeconfig`（doctl）で取ると、doctl 経由で再認証する context になる。
- **surge_upgrade**: 1ノード構成なので、upgrade 中に pod の退避先が無くならないよう有効にしている。その間だけノードが1台増え、その分は課金される。
- **destroy**: `destroy_all_associated_resources = true`。`type: LoadBalancer` の Service や PVC が作った LB / volume はクラスタとは別課金で、これが無いと destroy 後も残って課金され続ける。
- **置換系の変更に注意**: VPC の `ip_range` は作成後変更不可（変えると VPC 置換 → クラスタも置換）。cluster の `region` / node pool の `name` も同様。
- `prevent_destroy` は**あえて付けていない**。中身は GitOps で作り直せるので、使わない期間に `terraform destroy` で課金を止められる方を優先した。

## Argo CD

- **version の固定**: `argocd/kustomization.yaml` の remote base の `?ref=` が version。上げるときはそこを書き換える（Image Updater も同様に `argocd/image-updater/`）。
- **upstream は resource requests を持たない**。1ノード構成では scheduler が判断できないので、component ごとに patch で下限と memory の上限を付けている。memory が苦しくなったら `argocd-notifications-controller` と `argocd-applicationset-controller` を replicas 0 にする余地がある（どちらも今は使っていない）。
- **dex は replicas 0**。SSO を使わないので常駐させる意味がない。
- **適用は server-side apply**（`kubectl apply -k argocd --server-side`）。Argo CD の CRD は client-side apply の annotation サイズ上限を超える。同じ理由で self-manage する Application にも `ServerSideApply=true` を付けてある。
- **自己管理**: `applications/argocd.yaml` が `argocd/` を同期する。`prune: false` にしてあるのは、path を間違えたときに自分を消させないため。
- **app of apps**: `applications/root.yaml` が `applications/` の**直下のファイルだけ**を同期する（`recurse: false`）。サブディレクトリは各アプリの manifest で、それは個々の Application が同期するため、root が拾うと二重管理になる。アプリを増やす操作は `<name>.yaml` と `<name>/` を足すこと。
- **Image Updater**: イメージのビルドは各アプリの repo、manifest はこの repo という分担なので、tag の更新は Image Updater が担う。git write-back の書き込み先は Application の source repo、つまり**この repo**。そのための書き込み credential をクラスタ内の Secret に置く必要があり、**その Secret は git に入れず `kubectl` で作る**。v1.x は Application の annotation に加えて `ImageUpdater` CRD でも設定できる。

## remote MCP サーバー（`applications/remote-mcp-server/`）

- **リポジトリ間の分担**: image のビルドは boykush/wiki（wiki のコンテンツ + scraps バイナリを同梱）、manifest はこの repo。両者を繋ぐのが Image Updater。
- **image の契約**: `ghcr.io/boykush/remote-mcp-server`、tag は可変の `main` 固定で digest だけが動く。`SCRAPS_DIRECTORY` は image 側で設定する（コンテンツの置き場所は wiki 側の都合なので、Deployment からは触らない）。GHCR の package は public でないと pull できない。
- **update strategy が `digest` なのは tag が動かないから**。`newest-build` や `semver` は tag 名の変化を前提にしている。
- **git write-back の credential**: Secret `argocd/image-updater-git-creds`（`username` / `password`）を **`kubectl` で手元から作る**。git には入れない。この repo への push 権限が要るので、Argo CD の read 用とは別物。fine-grained PAT をこの repo に絞るのが無難。
- **無認証**: `scraps mcp serve --http` は認証も TLS も持たない（公式にも "not meant to be exposed to a network"）。Service は ClusterIP 止まりで、利用は port-forward。外部公開するなら前段に認証を置く。
