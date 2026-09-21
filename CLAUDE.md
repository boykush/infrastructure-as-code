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
- CI は secret `TF_API_TOKEN`（HCP backend）、`DIGITALOCEAN_ACCESS_TOKEN`、`CLOUDFLARE_API_TOKEN`（provider）、`ACCESS_OWNER_EMAIL`（`TF_VAR_access_owner_email`。public repo にメールアドレスを置かないため）。tfcmt は built-in の `GITHUB_TOKEN` を使う——owner 全体の default workflow permissions が read に絞られているため、job の `permissions:` で `pull-requests: write` / `issues: write` を戻している。

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
- **Image Updater**: イメージのビルドは各アプリの repo、manifest はこの repo という分担なので、tag の更新は Image Updater が担う。git write-back の書き込み先は Application の source repo、つまり**この repo**。そのための書き込み credential をクラスタ内の Secret に置く必要があり、**その Secret は git に入れず `kubectl` で作る**。
- **v1.x の設定は `ImageUpdater` CR だけ**。Application の annotation は `useAnnotations` を立てない限り読まれず、CR が1つも無いと controller は「対象なし」を回し続ける（v1.0.0 で annotation ベースから移行済み）。CR は `applications/remote-mcp-server/imageupdater.yaml` に置き、**namespace は `argocd`**——controller は自分の namespace しか見ず、CR が選べるのは隣に居る Application だけ。

## MCP サーバー（`applications/remote-mcp-server/`）

- **1 Application、サーバーごとにディレクトリ**。`applications/remote-mcp-server/<name>/` が1つの MCP サーバーで、root の `kustomization.yaml` が `resources` で束ねる。共通しているのは「MCP サーバーである」ことだけなので、Application を分けずに namespace を共有している。増やす手順は README。
- **`images:` は root の kustomization に置く**。Image Updater の `write-back-target: kustomization` は Application の `path` にある kustomization.yaml へ書くので、per-server のディレクトリに置くと書き戻し先とずれる。
- **リソース名はサーバー名**（`wiki` であって `remote-mcp-server` ではない）。namespace が既に「MCP サーバー群」を意味しているので、名前が担うのは「どれか」の方。
- **リポジトリ間の分担**: image のビルドは各アプリの repo（wiki なら boykush/wiki が wiki のコンテンツ + scraps バイナリを、adr なら boykush/adr が決定と `.rule` + adi バイナリを同梱）、manifest はこの repo。両者を繋ぐのが Image Updater。エージェント側の接続設定は boykush/ai-plugins が apm package として配る（`plugins/wiki-remote-mcp` が MCP サーバー名 `scraps`、`plugins/adr-remote-mcp` が `adr`）ので、この repo には書かない。
- **image の契約**（boykush/wiki の `Dockerfile` と workflow が決めている側）:
  - `ghcr.io/boykush/wiki-mcp-server`。可変の `main` と、`<scraps version>-<sha7>` の2つが push される。追うのは `main`。
  - ENTRYPOINT が `scraps mcp serve --http` なので、**`args` に渡すのは listen アドレスだけ**。`mcp serve` から書くと二重になって起動しない。
  - `SCRAPS_DIRECTORY=/wiki/scraps` は image 側で設定済み。コンテンツの置き場所は wiki 側の都合なので Deployment からは触らない。
  - GHCR の package は public。
- **adr の image の契約**（boykush/adr の `Dockerfile` と workflow が決めている側）:
  - `ghcr.io/boykush/adr-mcp-server`。可変の `main` と、`<sha7>` の2つが push される。追うのは `main`。fork をやめて boykush/adr 自身のソースからビルドするようになったので、tag は commit だけで決まる。
  - ENTRYPOINT が `adi mcp --model decisions --http` なので、`args` に渡すのは listen アドレスだけ。model の置き場所は adr 側の都合なので Deployment からは触らない。
  - GHCR の package は public。
- **update strategy が `digest` なのは tag が動かないから**。`newest-build` や `semver` は tag 名の変化を前提にしている。
- **git write-back の credential は GitHub App**（`githubAppID` / `githubAppInstallationID` / `githubAppPrivateKey`）。Secret `argocd/image-updater-git-creds` は **Actions の Image Updater Credential（`workflow_dispatch`）が適用する**。git には入れない——private key は repo secret、2つの id は variable。**PAT では main に push できない**——`boykush/github-management` が張る ruleset（Require pull request / Required check: zizmor）の bypass actor になれるのは App だけなので、専用 App を作って両 ruleset の bypass に足す。Argo CD の read 用 credential とは別物。
- **公開は無認証**: `scraps mcp serve --http` は認証も TLS も持たない（公式にも "not meant to be exposed to a network"）。それでもインターネットに出しているのは、wiki の内容が元から公開で MCP 側が読み取り専用だから——前段の認証は**あえて置いていない**判断。絞るなら Cloudflare の rate limit / Access を被せる側で、manifest は触らない。adr も同じ理由で無認証——boykush/adr は public で、adi の MCP も認証を持たない読み取り専用。
- **scraps は Host ヘッダを検証する**。rmcp の DNS リバインディング対策で、既定の許可リストは `localhost` / `127.0.0.1` / `::1`。公開ホスト名を通すには Deployment の `--allowed-host` に渡す（scraps v1.2.0 以降。loopback は置き換えでなく追加なので port-forward も生きる）。**Cloudflare 側の HTTP Host Header 書き換えは使わない**——一時期の回避策で、`--allowed-host` が入った時点で不要。
- **adi は loopback で受けた接続にしか Host 検証をかけない**。公式 Go SDK の既定と同じ判定で、tunnel からの接続は pod network 経由なので対象外。scraps の `--allowed-host` に当たる設定は無く、要らない。port-forward は pod の loopback に着くので、`localhost` / `127.0.0.1` で叩けば通る。
- **公開ホスト名は `<name>-mcp.<ドメイン>`**。エンドポイントのパスはどのサーバーも `/mcp` 固定なので、サーバーを区別できるのはホスト名だけ。総称の `mcp.<ドメイン>` を1つ目に取らせると2つ目で詰まる。2階層（`<name>.mcp.<ドメイン>`）は Cloudflare の Universal SSL が覆わない。
- **この値は public repo の manifest に載る**。ドメインを git の外に置く方針より、回避策を消して契約を1箇所に書く方を取った結果。

## Cloudflare Tunnel（`applications/cloudflared/`）

- **クラスタの出口であって、アプリの一部ではない**。だから MCP サーバーとは別の Application / namespace（`cloudflared`）にしてある。1本の tunnel が全ホスト名を捌くので、公開するものが増えても `cloudflared` は1つのまま。
- **なぜ tunnel で、LB でないか**: `cloudflared` がクラスタ内から dial out するので Service は ClusterIP のまま、ノードの public IP には何も開かず、DO の Load Balancer（$12/月〜）も増えない。NodePort は DOKS の管理 firewall が自動で全開放し送信元 IP で絞れないので、TLS の無い無認証エンドポイントの置き場所としては採らなかった。
- **route は Terraform**: remotely-managed tunnel なので hostname → Service の対応は Cloudflare 側の設定だが、それを書くのは `terraform/cloudflare.tf`。tunnel 本体・route・DNS の CNAME が揃っていて、触るのは `var.tunnel_routes` だけ。catch-all（`http_status:404`）は末尾に自動で付く。Service URL は namespace を跨ぐので **FQDN**（`<name>.remote-mcp-server.svc.cluster.local:<port>`）で書く。
- **zone / account ID は commit しない**: `data.cloudflare_zones` に `var.domain` を渡して両方引いている。API token に Zone: Zone (Read) が要るのはこのため（他は Account: Cloudflare Tunnel (Edit) と Zone: DNS (Edit)、Access 用に Access: Apps / Access: Policies / Access: Identity Providers（いずれも Write））。
- **アプリを増やすと2箇所**: `applications/` の manifest（scraps なら `--allowed-host` に公開ホスト名）と `terraform/variables.tf` の `tunnel_routes`。Terraform は manifest を読めないので、ホスト名はどうしても両方に書く。
- **token は Secret `cloudflared/cloudflared-tunnel-token`**（key は `token`）。Image Updater の git creds と同様 **`kubectl` で作り git には入れない**。
- **`cloudflared` の tag は手で上げる**: Image Updater が追うのは `ImageUpdater` CR に名指しされた Application だけで、この Application は名指しされていない。

## Backstage（`applications/backstage/`）

- **公式 image をそのまま使う**。自前の build は無く、設定は `app-config.yaml` を configMapGenerator で ConfigMap にして image 既定の設定に重ねる。image の CMD は `app-config.production.yaml`（PostgreSQL 前提）も読むので、`args` で置き換えて外している。
- **公開は Cloudflare Access の後ろだけ**。guest サインインを本番で許す `dangerouslyAllowOutsideDevelopment` と allow-all の permission で動いているので、Access が無いと誰でも catalog を書き換えられ、scaffolder の試し実行で GitHub token が読める private repo の中身まで引き出せる。`terraform/access.tf` がワンタイム PIN で owner のアドレスだけを通し、tunnel の routing table は `depends_on` でその application ができるのを待つ。MCP として配るときは、wiki / adr と同じく `remote-mcp-server` 側に並べる形で別に考える（未着手）。
- **catalog は `readonly`**。location の登録・解除は拒否される。entity を直接消す API（`DELETE /entities/by-uid`）は readonly でも通るが、消しても数秒で github-management から読み直されて戻る（手元の 1.55.0 で確認）。entity は github-management からしか入らない。
- **catalog の中身は github-management が持つ**。こちらが知るのは入口の URL と、Catalog Graph の起点にしている owner（`user:boykush`）だけで、repo 名は書かない。入口の location に付けた `rules` は入口の URL で照合されるので、`targets` の先で読まれる User にも効く。
- **状態を持たない**。DB は image 既定のメモリ上の SQLite で、catalog は起動のたびに GitHub から読み直す。PVC を作らない（DO の volume は別課金）。夜間停止で Pod が作り直されても困らない。
- **root filesystem は read-only**。書き込み先は `/tmp` の emptyDir だけ。image の USER は名前（`node`）なので、`runAsNonRoot` を満たすために `runAsUser: 1000` を明示している。
- **token は Secret `backstage/backstage-github-token`**（key は `token`）。`kubectl` で作り git には入れない。github-management が private なので Contents: read が要る。
- **tag は手で上げる**（`cloudflared` と同じく Image Updater の対象外）。
