# AGENTS.md

boykush の個人アプリケーションを載せる Kubernetes 基盤の IaC リポジトリ。DOKS クラスタを Terraform（`digitalocean/digitalocean` provider）で、その上のアプリケーションを Argo CD で管理する。構成値と手順は README を、個々のファイルの制約とその理由はそのファイルのコメントを見る。ここに書くのは、どれか1つのファイルには収まらないもの——横断する禁止、踏んだ失敗、他の repo との契約——だけ。

## レイアウト

- `terraform/` — クラスタ本体（VPC + DOKS cluster + node pool）。root module は1つだけで、環境の分岐も tfvars も無い。`variables.tf` の default がそのまま live の設定。
- `argocd/` — Argo CD 本体 + Image Updater。kustomize の remote base を tag で固定している。
- `applications/` — アプリごとに `<name>.yaml`（Argo CD の Application）と `<name>/`（その manifest）を並べる。イメージのビルドは各アプリの repo が行い、ここにはその成果物を指す manifest だけが載る。

## Toolchain

- provider は `.terraform.lock.hcl` で固定（**commit する**）。`versions.tf` の `~> 2.0` は緩いので、実際に使う version を決めているのは lock file。更新は **全 platform を明示**して行う:
  ```sh
  mise exec -- terraform providers lock \
    -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64
  ```

## Backend / 認証

- **workspace を作り直したら Execution Mode を Local に戻す**。新規作成時の default は remote で、そのままだと HCP 側で実行され、DO token が無い環境で plan が落ちる。
- provider の認証は `DIGITALOCEAN_ACCESS_TOKEN`。provider が優先して読むのは `DIGITALOCEAN_TOKEN` だが、doctl が読むのは `DIGITALOCEAN_ACCESS_TOKEN` だけなので、1変数で両方賄えるこちらに寄せている。
- **`mise.toml` の `[env]` に手元専用の値を置けない**。shim が実行時に `[env]` を適用するので CI にも届く（`mise-action` の `env: false` でも回り込む）。`add_shims_to_path: false` で shim を外すと今度は tool が PATH から消えて `exit 127`——`export_path` だけでは raw のバイナリは載らない。
- **bootstrap の apply は `-target` で AWS のリソースに絞る**。root module が1つなので素の plan は state 全体を refresh し、DO と Cloudflare の認証情報まで要求する。AWS のリソースはどちらにも依存していないので、targeting すればそれらの API は呼ばれない。残りは merge 後の CI の full apply が揃える。
- **信頼を壊す変更はローカル apply でしか直せない**。role を作るのは Terraform 自身で、CI はその role で動くため。

## ワークフロー

- **ローカル apply はしない**。唯一の例外がクラスタの初回 bootstrap（CI の secret 登録より先にクラスタが要ったため）。
- **workflow には `permissions:` を書く**。owner 全体の既定が read に絞られている（github-management が配っている）ので、書かないと write が要る step だけが落ちる。
- 残作業・TODO は **Issue で管理する**。README に書くのは現状の構成と手順だけで、作業項目のリストは置かない。
- **repo は public だが、識別子は伏せない**。`sensitive` を付けるのは資格情報と個人情報だけ。UUID・account ID・endpoint のような識別子は、token が無ければ何も開けない。そのうえ `sensitive` が隠すのは差分と output の値だけで、resource の id は plan / apply の出力にそのまま出るので、付けても隠したことにならない。

## DOKS の勘所

- **version と auto_upgrade**: `version` は `digitalocean_kubernetes_versions` data source が返す「pin した minor の最新 patch」。`auto_upgrade = true` なので patch 適用は DO がメンテナンス窓で行い、Terraform 側は追従するだけ。minor を上げる操作は `kubernetes_version_prefix` の編集。
- **新規作成できるのは最新3 minor だけ**（窓を過ぎた version は既存クラスタは動き続けるが新規作成不可）。現行は 1.34 / 1.35 / 1.36。手元での確認は `doctl kubernetes options versions`。
- **置換系の変更に注意**: VPC の `ip_range` は作成後変更不可（変えると VPC 置換 → クラスタも置換）。cluster の `region` / node pool の `name` も同様。
- `prevent_destroy` は**あえて付けていない**。中身は GitOps で作り直せるので、使わない期間に `terraform destroy` で課金を止められる方を優先した。

## Argo CD

- **version の固定**: `argocd/kustomization.yaml` の remote base の `?ref=` が version。上げるときはそこを書き換える（Image Updater も同様に `argocd/image-updater/`）。
- **anonymous を有効にしない**。UI は Backstage と同じ Access の内側にあるが、Access を唯一の鍵にはせず、Argo CD 自身のログインを残している（理由は `terraform/access.tf` の `argocd`）。

## MCP サーバー（`applications/remote-mcp-server/`）

- **公開は無認証**: `scraps mcp serve --http` は認証も TLS も持たない（公式にも "not meant to be exposed to a network"）。それでもインターネットに出しているのは、wiki の内容が元から公開で MCP 側が読み取り専用だから——前段の認証は**あえて置いていない**判断。絞るなら Cloudflare の rate limit / Access を被せる側で、manifest は触らない。adr も同じ理由で無認証——boykush/adr は public で、adi の MCP も認証を持たない読み取り専用。
- **Cloudflare 側の HTTP Host Header 書き換えは使わない**。Deployment が渡す `--allowed-host` が入った時点で不要になった、一時期の回避策。
- **公開ホスト名は `<name>-mcp.<ドメイン>`**。エンドポイントのパスはどのサーバーも `/mcp` 固定なので、サーバーを区別できるのはホスト名だけ。総称の `mcp.<ドメイン>` を1つ目に取らせると2つ目で詰まる。2階層（`<name>.mcp.<ドメイン>`）は Cloudflare の Universal SSL が覆わない。
- **この値は public repo の manifest に載る**。ドメインを git の外に置く方針より、回避策を消して契約を1箇所に書く方を取った結果。

## Cloudflare Tunnel（`applications/cloudflared/`）

- **NodePort は採らなかった**。DOKS の管理 firewall が自動で全開放し送信元 IP で絞れないので、TLS の無い無認証エンドポイントの置き場所にならない。
- **アプリを増やすと2箇所**: `applications/` の manifest（scraps なら `--allowed-host` に公開ホスト名）と `terraform/variables.tf` の `tunnel_routes`。Terraform は manifest を読めないので、ホスト名はどうしても両方に書く。
- **Access で守るホスト名は、その application を `terraform/cloudflare.tf` の `depends_on` にも載せる**。載せないと、初回の apply で route が Access より先に開きうる。

## Backstage（`applications/backstage/`）

- **catalog の中身は github-management が持つ**。こちら側が引き受けている分は `app-config.yaml` と `deployment.yaml` のコメントに、向こう側の契約は `catalog/all.yaml`・`catalog/Dockerfile`・`.github/workflows/catalog-image.yml` のコメントにある。catalog の形を変えるときは両方の repo を触る。

## AWS の認証情報（`terraform/aws.tf`）

- **トークンは Terraform の resource にしない**。`aws_ssm_parameter` は refresh で値を読み戻すので、resource にすると HCP の state に平文が載る。Terraform が持つのは OIDC provider・role・権限だけで、parameter への書き込みは `mise run claude:token` が担う。`terraform plan` には parameter が存在するかどうかも出ない——空なら composite action が実行時に落ちる。
- **トークンに改行を混ぜない**。`::add-mask::` は行単位に効くので、改行が残ると**2行目が public repo のログに出る**——一度踏んだ。`mise run claude:token` が空白を落とすのはこのため。
- **repo を足す操作は `claude_code_repositories` に1行**。trust policy の `sub` がそこから組まれる（`repo:<owner>/<repo>:*`）。`repo:<owner>/*` に広げてはいけない——以後その owner が作る repo すべてがトークンを読めるようになる。
- **`sub` クレームは repo の作成時期で形式が違う**。2026-07-15 以降に作られた repo は ID 入り（`repo:<owner>@<owner_id>/<repo>@<repo_id>:...`）、それ以前は名前だけで opt-in 待ち。`local.claude_code_subjects` / `local.this_repository_subjects` / `local.github_app_subjects` が両形式を並べているのはこのため。**片方に削ってはいけない**——`claude_code_repositories` には両形式の repo が実際に混在している。
- **`local.account_id` は使えない**。`cloudflare.tf` が同名の local を持っている（Cloudflare の account id）。AWS 側は `local.aws_account_id`。この repo 自身の `sub` は `local.this_repository_subjects`——terraform の role と Image Updater の role が共有する。
- **GitHub App の private key も Terraform には通さない**。`key_material_base64` を渡すと HCP の state に載るので、Terraform が作るのは material の無い空の key（origin EXTERNAL、`PendingImport`）と role だけ。中身は `mise run app:key-import` が CLI で入れる。**material は key ごとに1度きり**なので、鍵を替えるなら `-replace` で key を作り直す（alias が向き先を吸収するので repo 側は無変更）。
- **role は App ごとに分ける**。`kms:Sign` を1つの role にまとめると、renovate-runner の run が全 repo を管理する App として署名できてしまう。App と repo の対応は `var.github_apps` だけが持つ。
- **CI に `kms:Sign` / `kms:ImportKeyMaterial` / `kms:PutKeyPolicy` を足さない**。`github-actions-terraform` は key を作れるが使えない、というのがこの構成の要で、どれか1つ足すと成立しなくなる。
- **CI の policy は、これから作る role を文字列で名指しする**。resource の ARN を読むと policy が role の後ろに並び、作る権限が作った後に来る。role 名を `local.github_app_role_names` に置いて policy と resource の両方がそれを使い、`depends_on = [aws_iam_role_policy.terraform]` で更新を先に走らせている——**これがあるからローカル apply が要らない**。KMS の key は ARN を先に書けないので `key/*` と `alias/*` で絞る。
- トークンを構造的に無くす道は [Claude 自身の WIF](https://platform.claude.com/docs/en/manage-claude/workload-identity-federation)（`anthropic_federation_rule_id`、`claude-code-action` が対応済み）だが、**API 従量課金**になり Max のシートでは使えない。この repo が AWS を選んだのはそのため。
