# infrastructure-as-code

boykush の個人アプリケーションを載せる Kubernetes 基盤のリポジトリ。クラスタ（DigitalOcean Kubernetes / DOKS）を Terraform で作り、その上のアプリケーションは Argo CD で GitOps デプロイする。

## クラスタ

| 項目 | 値 | 補足 |
| --- | --- | --- |
| region | `sgp1`（Singapore） | DO に東京リージョンは無く、日本から最も近い |
| Kubernetes | `1.36` 系 | patch は DO の auto-upgrade 任せ。minor は `kubernetes_version_prefix` で固定 |
| node pool | `s-2vcpu-4gb` × 1 | $24/月。Argo CD + DOKS の system pod が載る実質の下限 |
| control plane | 非 HA | 無料。HA にすると +$40/月 |
| VPC | 専用 / `10.10.0.0/16` | 無料。`ip_range` は後から変更できない |
| maintenance | 日曜 19:00 UTC | = 月曜 04:00 JST |

## Argo CD

クラスタ上のアプリケーションは Argo CD（v3.5.1）で同期する。Argo CD 自身も Application として自己管理される。

| ディレクトリ | 中身 |
| --- | --- |
| `argocd/` | Argo CD 本体と Image Updater（kustomize の remote base を version 固定） |
| `applications/` | アプリごとに `<name>.yaml`（Application）と `<name>/`（manifest）。イメージのビルドは各アプリのリポジトリ側 |

### bootstrap（初回のみ）

```sh
mise exec -- kubectl apply -k argocd --server-side
mise exec -- kubectl -n argocd rollout status statefulset/argocd-application-controller
mise exec -- kubectl apply -f applications/root.yaml
```

以降は `applications/` にファイルを足せば root Application が拾う。

### remote MCP サーバー

MCP サーバーは `applications/remote-mcp-server/<name>/` にまとめて置き、1つの Application（namespace `remote-mcp-server`）で同期する。今載っているのは [boykush/wiki](https://github.com/boykush/wiki) を scraps の MCP サーバーにした `wiki` だけ。イメージは各アプリ側の CI が GHCR へ push し、新しい digest は Image Updater が `applications/remote-mcp-server/kustomization.yaml` に書き戻す。

公開は Cloudflare Tunnel 経由（`applications/cloudflared/`）。`cloudflared` がクラスタ内から Cloudflare へ張った接続を traffic が下ってくるので、Service は ClusterIP のままで、ノードの public IP には何も開かない。DigitalOcean の Load Balancer（$12/月〜）が要らないのはこのため。TLS と公開ホスト名は Cloudflare 側が持つ。**tunnel は1本で全ホスト名を捌く**ので、サーバーが増えても `cloudflared` は増えない。

```sh
claude mcp add --transport http wiki https://<wiki のホスト名>/mcp
```

**この MCP は無認証で公開している**——wiki の内容は元から公開で、scraps の MCP は読み取り専用なので、前段に認証を置いていない。絞りたくなったら Cloudflare 側で rate limit や Access を被せられる（クラスタ側の manifest は変更不要）。

#### MCP サーバーを増やす

1. `applications/remote-mcp-server/<name>/` に Deployment / Service / kustomization を置く
2. `applications/remote-mcp-server/kustomization.yaml` の `resources` と `images` に1行ずつ足す
3. `applications/remote-mcp-server.yaml` の `image-list` に `<name>=<image>` を足し、`<name>.update-strategy` を決める
4. Cloudflare のダッシュボードで public hostname を1つ足す（下記）

#### tunnel のセットアップ（初回のみ）

hostname → Service の対応は Cloudflare のダッシュボード側にある（remotely-managed tunnel）。Zero Trust の Networks → Tunnels で cloudflared タイプの tunnel を作り、public hostname の Service URL に **クラスタ内から見た FQDN** を書く。

```
http://<name>.remote-mcp-server.svc.cluster.local:<port>
```

`cloudflared` は別 namespace に居るので短縮名では引けない。token は credential なので git に入れず手元で Secret にする。

```sh
mise exec -- kubectl -n cloudflared create secret generic cloudflared-tunnel-token \
  --from-literal=token=<tunnel token>
```

Secret ができるまで `cloudflared` の Pod は `CreateContainerConfigError` で止まる。

**scraps は Host ヘッダを検証する**（rmcp の DNS リバインディング対策）。許可されるのは localhost 系だけなので、公開ホスト名のままでは 403 `Forbidden: Host header is not allowed` になる。route の Additional application settings → HTTP Settings → HTTP Host Header に `localhost` を入れて回避している（rmcp の既定の許可リストは `localhost` / `127.0.0.1` / `::1`）。scraps 側に許可ホストを渡す口ができたらこの設定は外せる。

port-forward も従来どおり使える。tunnel を疑うときの切り分けに。

```sh
mise exec -- kubectl -n remote-mcp-server port-forward svc/wiki 1113:1113
```

Image Updater の git write-back にはこのリポジトリへの push 権限が要る（Argo CD は読むだけなので別の credential）。Secret は git に入れず手元で作る。

```sh
mise exec -- kubectl -n argocd create secret generic image-updater-git-creds \
  --from-literal=username=boykush --from-literal=password=<fine-grained PAT>
```

### UI

```sh
mise exec -- kubectl -n argocd port-forward svc/argocd-server 8080:443
mise exec -- kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

`https://localhost:8080` に admin で入る。証明書は自己署名なので警告が出る。

## Toolchain

Terraform / doctl / kubectl を [mise](https://mise.jdx.dev/) で固定（`mise.toml`）。

```sh
mise install   # mise.toml のバージョンで導入
```

kubectl をリポジトリ側で固定しているのは、マシン全体の client（1.30）が DOKS 1.36 に対して skew（±1 minor）を超えているため。

## Local development

state は HCP Terraform（`cloud {}` backend）にあるので、`init` 以降は認証が要る。

```sh
mise install                            # toolchain を導入
mise run tf:login                       # HCP backend 認証（一度だけ）
doctl auth init                         # DO の PAT を入力（~/.config/doctl/config.yaml に保存）
export DIGITALOCEAN_ACCESS_TOKEN=...    # provider 用（doctl と同じ変数名）

cd terraform
mise exec -- terraform init
mise exec -- terraform plan
```

- `terraform fmt` は認証不要。
- **`apply` はローカルで実行しない**——main への push で CI が行う。クラスタの初回 bootstrap だけは例外的にローカルから apply した。
- kubeconfig は `mise run k8s:kubeconfig`（`doctl kubernetes cluster kubeconfig save`）で取る。context 名は `do-sgp1-boykush-cluster`。

## CI（`.github/workflows/terraform.yml`）

| トリガ | 動作 |
| --- | --- |
| PR | `terraform plan`（tfcmt がコメント） |
| push to main | `terraform apply` |

| secret | 用途 |
| --- | --- |
| `TF_API_TOKEN` | HCP backend（`TF_TOKEN_app_terraform_io` 経由） |
| `DIGITALOCEAN_ACCESS_TOKEN` | `digitalocean` provider |

HCP の workspace `infrastructure-as-code` は Execution Mode = **Local**（実行は CLI / CI 側、HCP は state + lock のみ）。

## 費用

課金されるのは worker node（$24/月）だけで、control plane と VPC は無料。MCP サーバーの公開に Cloudflare Tunnel を使っているのも、Load Balancer（$12/月〜）を増やさないため。使わない期間は `terraform destroy` で止められる——`destroy_all_associated_resources = true` なので、クラスタが作った LoadBalancer / volume も一緒に消える。
