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

MCP サーバーは `applications/remote-mcp-server/<name>/` にまとめて置き、1つの Application（namespace `remote-mcp-server`）で同期する。今載っているのは [boykush/wiki](https://github.com/boykush/wiki) を scraps の MCP サーバーにした `wiki` だけ。イメージは各アプリ側の CI が GHCR へ push し、新しい digest は Image Updater が `applications/remote-mcp-server/kustomization.yaml` に書き戻す。何を追うかは `applications/remote-mcp-server/imageupdater.yaml`（`ImageUpdater` CR）で決める——v1.x は Application の annotation を読まない。

公開は Cloudflare Tunnel 経由（`applications/cloudflared/`）。`cloudflared` がクラスタ内から Cloudflare へ張った接続を traffic が下ってくるので、Service は ClusterIP のままで、ノードの public IP には何も開かない。DigitalOcean の Load Balancer（$12/月〜）が要らないのはこのため。TLS と公開ホスト名は Cloudflare 側が持つ。**tunnel は1本で全ホスト名を捌く**ので、サーバーが増えても `cloudflared` は増えない。

```sh
claude mcp add --transport http wiki https://wiki-mcp.boykush.com/mcp
```

エンドポイントのパスは scraps 側で `/mcp` 固定なので、サーバーを区別できるのはホスト名だけ。`<name>-mcp.<ドメイン>` で並べる。Cloudflare の Universal SSL が覆うのは1階層目までなので、`<name>.mcp.<ドメイン>` のような2階層は使わない。

**この MCP は無認証で公開している**——wiki の内容は元から公開で、scraps の MCP は読み取り専用なので、前段に認証を置いていない。絞りたくなったら Cloudflare 側で rate limit や Access を被せられる（クラスタ側の manifest は変更不要）。

#### MCP サーバーを増やす

1. `applications/remote-mcp-server/<name>/` に Deployment / Service / kustomization を置く
2. `applications/remote-mcp-server/kustomization.yaml` の `resources` と `images` に1行ずつ足す
3. `applications/remote-mcp-server/imageupdater.yaml` の `images` に `alias` / `imageName` / `updateStrategy` を1つ足す
4. `terraform/variables.tf` の `tunnel_routes` に `subdomain` と `service` を1つ足す

#### tunnel の設定

tunnel 本体・route（hostname → Service）・DNS の CNAME はすべて `terraform/cloudflare.tf` にある（remotely-managed tunnel なので、route は Cloudflare 側に置かれた設定を Terraform が書く）。編集するのは `terraform/variables.tf` の `tunnel_routes` だけ。

```hcl
{
  subdomain = "wiki-mcp"
  service   = "http://wiki.remote-mcp-server.svc.cluster.local:1113"
}
```

`service` は **クラスタ内から見た FQDN**。`cloudflared` は別 namespace に居るので短縮名では引けない。catch-all（`http_status:404`）と CNAME は `subdomain` から自動で付く。

zone ID と account ID は書かず `var.domain` から引いている（public repo に識別子を置かないため）。API token に要る権限は Account: Cloudflare Tunnel (Edit) / Zone: DNS (Edit) / Zone: Zone (Read)。

token は credential なので git に入れず手元で Secret にする。tunnel を作り直したときだけやり直す。

```sh
mise exec -- kubectl -n cloudflared create secret generic cloudflared-tunnel-token \
  --from-literal=token="$(mise exec -- terraform -chdir=terraform output -raw tunnel_token)"
```

Secret ができるまで `cloudflared` の Pod は `CreateContainerConfigError` で止まる。

**scraps は Host ヘッダを検証する**（rmcp の DNS リバインディング対策）。既定の許可リストは `localhost` / `127.0.0.1` / `::1` だけなので、公開ホスト名で叩くと 403 `Forbidden: Host header is not allowed` になる。Deployment の `--allowed-host` に公開ホスト名を渡して許可する（scraps v1.2.0 以降）。loopback は残るので port-forward も併用できる。**Cloudflare 側で HTTP Host Header を書き換える設定は不要**——入っていたら外す。

port-forward も従来どおり使える。tunnel を疑うときの切り分けに。

```sh
mise exec -- kubectl -n remote-mcp-server port-forward svc/wiki 1113:1113
```

Image Updater の git write-back には main への push 権限が要る（Argo CD は読むだけなので別の credential）。**PAT では通らない**——main の ruleset（`boykush/github-management` が張る Require pull request / Required check: zizmor）を bypass できるのは GitHub App だけなので、専用の App を作り、その App id を両 ruleset の bypass actor に足す。App に要る権限は Contents: write、install 先はこのリポジトリだけでいい。

credential をクラスタに入れるのは Actions の **Image Updater Credential**（`workflow_dispatch`）。手元に DO の PAT を持たなくてよく、鍵を替えたときもクラスタを作り直したときも同じ workflow を回すだけで戻る。

先に一度だけ App の3つの値を登録する。private key だけが secret で、2つの id は識別子なので variable にしてある。

```sh
gh variable set IMAGE_UPDATER_APP_ID --body 4703313
gh variable set IMAGE_UPDATER_APP_INSTALLATION_ID --body <Installation ID>
gh secret set IMAGE_UPDATER_APP_PRIVATE_KEY < <app>.private-key.pem
```

```sh
gh workflow run image-updater-credential.yml
```

`githubAppID` に入れるのは **App ID**（数値）。GitHub は JWT の `iss` に Client ID を使うことを推奨しているが、Image Updater は base 10 で parse するので Client ID を入れると `invalid value in field githubAppID` で落ちる。ruleset の bypass actor に足す `actor_id` も同じ App ID。

Secret ができるまで Image Updater は新しい digest を見つけても書き戻せない。Pod は落ちず、`could not get creds for repo` がログに出続けるだけなので、digest が動かないときはまずここを見る。

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
| `CLOUDFLARE_API_TOKEN` | `cloudflare` provider（tunnel と DNS） |
| `IMAGE_UPDATER_APP_PRIVATE_KEY` | Image Updater の GitHub App（id 2つは variable） |

手動実行の workflow は **Image Updater Credential**（`workflow_dispatch`）の1つだけ。Image Updater の GitHub App credential を Secret `argocd/image-updater-git-creds` として適用する。Secret を書くので push では起動しない。

HCP の workspace `infrastructure-as-code` は Execution Mode = **Local**（実行は CLI / CI 側、HCP は state + lock のみ）。

## 費用

課金されるのは worker node（$24/月）だけで、control plane と VPC は無料。MCP サーバーの公開に Cloudflare Tunnel を使っているのも、Load Balancer（$12/月〜）を増やさないため。使わない期間は `terraform destroy` で止められる——`destroy_all_associated_resources = true` なので、クラスタが作った LoadBalancer / volume も一緒に消える。
