# AGENTS.md

boykush の個人アプリケーションを載せる Kubernetes 基盤の IaC リポジトリ。DOKS クラスタを Terraform（`digitalocean/digitalocean` provider）で、その上のアプリケーションを Argo CD で管理する。構成値と手順は README を見る。

## レイアウト

- `terraform/` — クラスタ本体（VPC + DOKS cluster + node pool）。root module は1つだけで、環境の分岐も tfvars も無い。`variables.tf` の default がそのまま live の設定。
- `argocd/` — Argo CD 本体 + Image Updater。kustomize の remote base を tag で固定している。
- `applications/` — アプリごとに `<name>.yaml`（Argo CD の Application）と `<name>/`（その manifest）を並べる。イメージのビルドは各アプリの repo が行い、ここにはその成果物を指す manifest だけが載る。

## Toolchain

- Terraform / doctl / kubectl / AWS CLI は mise で固定（`mise.toml`）。セットアップは `mise install`、version 変更は `mise.toml` の編集だけ。AWS CLI は手元と CI の両方で使う——他の repo から呼ばれる composite action と、Parameter Store から App の鍵を読む Image Updater Credential。**node は `[tools]` ではなく `app:key-import` の task tool**——KMS が要求する AES-KWP を持つのが手元では node の `crypto` だけで、task の tool は `mise install` が入れないので CI には降りない。
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
- **`mise.toml` の `[env]` は CI にも届く**。tool は shim として PATH に載り、shim は実行時に `[env]` を適用するので、`mise-action` の `env: false` で `GITHUB_ENV` を塞いでも回り込む。`add_shims_to_path: false` で shim を外すと今度は tool が PATH から消えて `exit 127`（`export_path` だけでは raw のバイナリは載らない）。つまり**手元専用の値を `[env]` に置けない**——`AWS_PROFILE` を置かず profile 名を `default` にしてあるのはこのため。名前付きだと CI の terraform が `failed to get shared config profile` で落ちる。
- **bootstrap の apply は `-target` で AWS のリソースに絞る**。root module が1つなので素の plan は state 全体を refresh し、DO と Cloudflare の認証情報まで要求する。AWS のリソースはどちらにも依存していないので、targeting すればそれらの API は呼ばれない。残りは merge 後の CI の full apply が揃える。**KMS と App の role は CI の apply で作れる**——CI 自身の policy がそれらの ARN を文字列で名指しし、`depends_on` でその更新が先に来るようにしてある。
- **`aws login` は profile を書く**ので、`[env]` が `AWS_CONFIG_FILE` を repo の `.aws/config` に向けている（`~/.aws/config` は作られない）。中身は識別子だけだがログインし直せば再生成されるため `.gitignore` 済み。`AWS_REGION` も張ってあるのは、未設定だと `aws login` が対話で訊いてくるため。
- AWS の認証は、CI は `github-actions-terraform` を GitHub OIDC で assume する（`aws-actions/configure-aws-credentials`）。**手元は `aws login`**——コンソールのサインイン（パスキー）から最大12時間の一時認証情報を取る CLI 2.32.0 以降の機能で、access key も Identity Center も要らない。aws provider は `login_session` を解釈するので、`AWS_PROFILE` 以外に渡すものは無い——**`aws configure export-credentials` で env に固めない**。返るのは15分で切れる認証情報で、env は profile より優先されるため期限切れ後に詰まる。**access key は作らない**。SSO を使っていないのは、単一アカウントで有効化した Identity Center が account instance になり、permission set もアカウント割り当ても持てないため。**role の ARN は workflow と composite action に直接書く**——account id は secret ではなく、variable に逃がすと呼び出し側の repo ごとに set して回ることになる。role を作るのは Terraform 自身なので、**信頼を壊す変更はローカル apply でしか直せない**。
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
- **v1.x の設定は `ImageUpdater` CR だけ**。Application の annotation は `useAnnotations` を立てない限り読まれず、CR が1つも無いと controller は「対象なし」を回し続ける（v1.0.0 で annotation ベースから移行済み）。CR はアプリのディレクトリに置き（`applications/remote-mcp-server/imageupdater.yaml` と `applications/backstage/imageupdater.yaml`）、**namespace は `argocd`**——controller は自分の namespace しか見ず、CR が選べるのは隣に居る Application だけ。

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
- **git write-back の credential は GitHub App**（`githubAppID` / `githubAppInstallationID` / `githubAppPrivateKey`）。Secret `argocd/image-updater-git-creds` は **Actions の Image Updater Credential（`workflow_dispatch`）が適用する**。git には入れない——private key は Parameter Store（`/image-updater/app-private-key`）に置き、workflow が OIDC で読む。2つの id は variable。**この App の鍵だけ KMS に入れられない**——Image Updater はクラスタの中で自分で JWT に署名するので、鍵そのものが要る。**PAT では main に push できない**——`boykush/github-management` が張る ruleset のうち push を止めるもの（Require pull request と required check）の bypass actor になれるのは App だけなので、専用 App を作り、github-management がそれらすべての bypass に足している。Argo CD の read 用 credential とは別物。
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
- **公開は Cloudflare Access の後ろだけ**。guest サインインを本番で許す `dangerouslyAllowOutsideDevelopment` と allow-all の permission で動いているので、Access が無いと、scaffolder の試し実行など guest に許した操作を誰でも動かせる。`terraform/access.tf` がワンタイム PIN で owner のアドレスだけを通し、tunnel の routing table は `depends_on` でその application ができるのを待つ。
- **catalog は MCP でも配る**（`/api/mcp-actions/v1/catalog`）。`remote-mcp-server` に別のサーバーを並べないのは、catalog を持っているのがこの Pod だから。既定の `/api/mcp-actions/v1` は登録済みの action を全部出すので、名前付きサーバーを切って `filter` で `catalog:*` に絞り、**Access はその path だけを bypass する**——エージェントは Access に見せる identity を持たず、allow では PIN フォームに送られる。Access は具体的な path から評価するので、`/api/mcp-actions/v1` 自身は owner だけの application に残る。
- **bypass で欠ける principal は Cloudflare が載せる**。Backstage は匿名の呼び出しでは action を動かさない（auth policy の管轄外）ので、transform rule が同じ path で `Authorization` を立て、`app-config.yaml` の `externalAccess` の static token と**値を一致させている**。読めるのが read-only の catalog だけなので、credential ではなく名札として平文で置いてある。エージェント側の接続設定は wiki / adr と同じく ai-plugins（`plugins/catalog-remote-mcp`、MCP サーバー名 `catalog`）が配る。
- **catalog は `readonly`**。location の登録・解除は拒否される。entity を直接消す API（`DELETE /entities/by-uid`）は readonly でも通るが、消しても数秒で catalog から読み直されて戻る（手元の 1.55.0 で、file と url の location の両方で確認）。entity は github-management の catalog からしか入らない。
- **catalog の中身は github-management が持つ**。こちらが知るのは catalog の image と、その中の入口（`/catalog/all.yaml`）、Catalog Graph の起点にしている owner（`user:boykush`）だけで、repo 名は書かない。入口の location に付けた `rules` は入口の location で照合されるので、`targets` の先で読まれる User にも効く。
- **状態を持たない**。DB は image 既定のメモリ上の SQLite で、catalog は起動のたびに image からコピーして読む。PVC を作らない（DO の volume は別課金）。夜間停止で Pod が作り直されても困らない。
- **root filesystem は read-only**。書き込み先は `/tmp` の emptyDir だけ。image の USER は名前（`node`）なので、`runAsNonRoot` を満たすために `runAsUser: 1000` を明示している。
- **catalog の image の契約**（boykush/github-management の AGENTS.md が決めている側）: `ghcr.io/boykush/github-management-catalog`。可変の `main` と commit SHA 7桁の2つが push され、追うのは `main`（Image Updater が digest で）。中身は `/catalog/*.yaml` で、init container の `cp -R /catalog/. /shared/` のために busybox を土台にしている。GHCR の package は public なので、GitHub の credential も pull 用の Secret も要らない。
- **Backstage 本体の tag は手で上げる**（`cloudflared` と同じく Image Updater の対象外。Image Updater が追うのは catalog の image だけ）。

## AWS の認証情報（`terraform/aws.tf`）

- **トークンは Terraform の resource にしない**。`aws_ssm_parameter` は refresh で値を読み戻すので、resource にすると HCP の state に平文が載る。Terraform が持つのは OIDC provider・role・権限だけで、parameter への書き込みは `mise run claude:token` が担う。`terraform plan` には parameter が存在するかどうかも出ない——空なら composite action が実行時に落ちる。
- **トークンに空白を混ぜない**。`mise run claude:token` は貼り付けから空白を落として `sk-ant-oat` 接頭辞を検証し、composite action は空白を含む値を読んだ時点で失敗する。改行が残ると `::add-mask::` が行単位に効かず、**2行目が public repo のログに出る**——一度踏んだ。
- **repo を足す操作は `claude_code_repositories` に1行**。trust policy の `sub` がそこから組まれる（`repo:<owner>/<repo>:*`）。`repo:<owner>/*` に広げてはいけない——以後その owner が作る repo すべてがトークンを読めるようになる。
- **`sub` クレームは repo の作成時期で形式が違う**。2026-07-15 以降に作られた repo は ID 入り（`repo:<owner>@<owner_id>/<repo>@<repo_id>:...`）、それ以前は名前だけで opt-in 待ち。`local.claude_code_subjects` / `local.this_repository_subjects` / `local.github_app_subjects` が両形式を並べているのはこのため。**片方に削ってはいけない**——`infrastructure-as-code` は新形式、`livt` と `renovate-runner` は旧形式で、実際に混在している。
- **`local.account_id` は使えない**。`cloudflare.tf` が同名の local を持っている（Cloudflare の account id）。AWS 側は `local.aws_account_id`。この repo 自身の `sub` は `local.this_repository_subjects`——terraform の role と Image Updater の role が共有する。
- **GitHub App の private key も Terraform には通さない**。`key_material_base64` を渡すと HCP の state に載るので、Terraform が作るのは material の無い空の key（origin EXTERNAL、`PendingImport`）と role だけ。中身は `mise run app:key-import` が CLI で入れる。**material は key ごとに1度きり**なので、鍵を替えるなら `-replace` で key を作り直す（alias が向き先を吸収するので repo 側は無変更）。
- **role は App ごとに分ける**。`kms:Sign` を1つの role にまとめると、renovate-runner の run が全 repo を管理する App として署名できてしまう。App と repo の対応は `var.github_apps` だけが持つ。
- **CI に `kms:Sign` / `kms:ImportKeyMaterial` / `kms:PutKeyPolicy` を足さない**。`github-actions-terraform` は key を作れるが使えない、というのがこの構成の要で、どれか1つ足すと成立しなくなる。
- **CI の policy は、これから作る role を文字列で名指しする**。resource の ARN を読むと policy が role の後ろに並び、作る権限が作った後に来る。role 名を `local.github_app_role_names` に置いて policy と resource の両方がそれを使い、`depends_on = [aws_iam_role_policy.terraform]` で更新を先に走らせている——**これがあるからローカル apply が要らない**。KMS の key は ARN を先に書けないので `key/*` と `alias/*` で絞る。
- **composite action は呼ぶ側で SHA 固定する**。zizmor が未固定の `uses:` を落とすので、自分の repo の action でも例外にならない（既存の `boykush/scraps@<sha>` と同じ扱い）。追従は Renovate。
- **`output-env-credentials: false` を外さない**。AWS の認証情報を job の環境に置かない設定で、後続の Claude の step が任意コードを実行することへの唯一の緩和になっている。読み取り step には `env:` で明示的に渡している。
- トークンを構造的に無くす道は [Claude 自身の WIF](https://platform.claude.com/docs/en/manage-claude/workload-identity-federation)（`anthropic_federation_rule_id`、`claude-code-action` が対応済み）だが、**API 従量課金**になり Max のシートでは使えない。この repo が AWS を選んだのはそのため。
