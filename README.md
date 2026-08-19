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

## アプリケーション

| ディレクトリ | 中身 |
| --- | --- |
| `applications/remote-mcp-server/` | scraps の remote MCP サーバー。wiki（[boykush/wiki](https://github.com/boykush/wiki)）は git-sync sidecar が5分ごとに pull する |

Argo CD を入れるまでは kustomize で直接適用する。

```sh
mise exec -- kubectl apply -k applications/remote-mcp-server
```

scraps の MCP サーバーは認証を持たないため Service は ClusterIP のみで、利用は port-forward 経由。

```sh
mise exec -- kubectl -n remote-mcp-server port-forward svc/remote-mcp-server 1113:1113
claude mcp add --transport http scraps http://127.0.0.1:1113/mcp
```

イメージ（`ghcr.io/boykush/remote-mcp-server`）は scraps のリリースバイナリを載せただけのもので、tag は scraps の version。ビルドと push は GH Actions が行う。

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

## CI

`.github/workflows/terraform.yml`:

| トリガ | 動作 |
| --- | --- |
| PR | `terraform plan`（tfcmt がコメント） |
| push to main | `terraform apply` |

`.github/workflows/remote-mcp-server-image.yml`（`Dockerfile` の変更時のみ）:

| トリガ | 動作 |
| --- | --- |
| PR | イメージを build（push はしない） |
| push to main | build して GHCR へ push |

| secret | 用途 |
| --- | --- |
| `TF_API_TOKEN` | HCP backend（`TF_TOKEN_app_terraform_io` 経由） |
| `DIGITALOCEAN_ACCESS_TOKEN` | `digitalocean` provider |

HCP の workspace `infrastructure-as-code` は Execution Mode = **Local**（実行は CLI / CI 側、HCP は state + lock のみ）。

## 費用

課金されるのは worker node（$24/月）だけで、control plane と VPC は無料。使わない期間は `terraform destroy` で止められる——`destroy_all_associated_resources = true` なので、クラスタが作った LoadBalancer / volume も一緒に消える。
