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

[boykush/wiki](https://github.com/boykush/wiki) を scraps の MCP サーバーとして載せている。イメージは wiki 側の CI が GHCR へ push し、新しい digest は Image Updater がこのリポジトリの `kustomization.yaml` に書き戻す。

サーバーは認証を持たないので Service は ClusterIP のみ。利用は port-forward 経由。

```sh
mise exec -- kubectl -n remote-mcp-server port-forward svc/remote-mcp-server 1113:1113
claude mcp add --transport http scraps http://127.0.0.1:1113/mcp
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

課金されるのは worker node（$24/月）だけで、control plane と VPC は無料。使わない期間は `terraform destroy` で止められる——`destroy_all_associated_resources = true` なので、クラスタが作った LoadBalancer / volume も一緒に消える。
