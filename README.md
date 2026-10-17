# infrastructure-as-code

boykush の個人アプリケーションを載せる Kubernetes 基盤のリポジトリ。クラスタ（DigitalOcean Kubernetes / DOKS）を Terraform で作り、その上のアプリケーションは Argo CD で GitOps デプロイする。

## クラスタ

region・node のサイズと台数・control plane・VPC・maintenance window は `terraform/variables.tf` と `terraform/main.tf` が持ち、選んだ理由はそれぞれのコメントにある。node の台数は作成後は夜間停止の workflow が持つ（→ [夜間停止](#夜間停止node-pool-parkyml--node-pool-resumeyml)）。

## Argo CD

クラスタ上のアプリケーションは Argo CD で同期する。Argo CD 自身も Application として自己管理される。

ディレクトリの分け方は AGENTS.md の「レイアウト」にある。

### bootstrap（初回のみ）

```sh
mise exec -- kubectl apply -k argocd --server-side
mise exec -- kubectl -n argocd rollout status statefulset/argocd-application-controller
mise exec -- kubectl apply -f applications/root.yaml
```

以降は `applications/` にファイルを足せば root Application が拾う。

### remote MCP サーバー

MCP サーバーは `applications/remote-mcp-server/<name>/` にまとめて置き、1つの Application（namespace `remote-mcp-server`）で同期する。どのサーバーがどの repo の何を配っているかは catalog が持つ（`type: mcp` の API と、それを provides する component）。イメージは各アプリ側の CI が GHCR へ push し、新しい digest は Image Updater が `applications/remote-mcp-server/kustomization.yaml` に書き戻す。何を追うかは `applications/remote-mcp-server/imageupdater.yaml`（`ImageUpdater` CR）で決める——v1.x は Application の annotation を読まない。

公開は Cloudflare Tunnel 経由（`applications/cloudflared/`）。`cloudflared` がクラスタ内から Cloudflare へ張った接続を traffic が下ってくるので、Service は ClusterIP のままで、ノードの public IP には何も開かない。DigitalOcean の Load Balancer（$12/月〜）が要らないのはこのため。TLS と公開ホスト名は Cloudflare 側が持つ。**tunnel は1本で全ホスト名を捌く**ので、サーバーが増えても `cloudflared` は増えない。

tunnel の先は各サーバーではなく agentgateway（`applications/agentgateway/`）で、Host を見て各サーバーへ振り分ける。置いている理由は trace の ID の橋渡し——クライアントは ID を HTTP ヘッダで渡し、サーバーは MCP の規約どおりリクエストの `_meta` から読むので、agentgateway がその間を写す。

この repo が持つのは公開エンドポイントまで（URL と MCP サーバー名は catalog の各 API の `definition`）。**エージェントに使わせる設定は担当外**で、[boykush/ai-plugins](https://github.com/boykush/ai-plugins) が apm package として配る。

catalog を引く MCP サーバーは Backstage が出すので、この Application には居ない（→ [Backstage](#backstage)）。ホスト名も取らず、`backstage.<ドメイン>` の path で分かれる。

公開ホスト名の付け方と、wiki・adr の MCP を無認証で公開している理由は AGENTS.md の「MCP サーバー」節にある。

#### 非公開の MCP の認証

finlake と Jaeger の MCP は同じ agentgateway の後ろに居るが、route が token を要求する（`applications/agentgateway/config.yaml` の `jwtAuth`）。入口は2つある。

**人が使うエージェント**は Access を通る。エージェントは GitHub へのリダイレクトを辿れないので、Access の Managed OAuth（`terraform/access.tf` の `oauth_configuration`）が入口になる——Access が 401 で OAuth の metadata を返し、GitHub ログインと owner policy を通した後に token を出す。通した request には Access が署名した JWT が `Cf-Access-Jwt-Assertion` ヘッダで付き、agentgateway はそれを Access の公開鍵と application の AUD tag で検証する。**Access は発行、agentgateway は検証**という分担で、Access を通らないクラスタ内からの呼び出しは JWT を持たないので agentgateway が落とす。`oauth_configuration` を変えた直後は数分待つ——反映されるまで metadata に `registration_endpoint` が載らず、クライアントは `does not support dynamic client registration` で落ちる。

**workflow** はログインできないので、Access の外に別のホスト名（`<name>-mcp-ci.<ドメイン>`。どのサーバーが持つかは `terraform/variables.tf` の `tunnel_routes`）を持つ。GitHub が run に発行する OIDC token を、そのホスト名を audience にして取り、`Authorization: Bearer` で渡す。agentgateway が GitHub の公開鍵で検証し、route の `authorization` が名指しする repo だけを通す。secret は配らない。job には `id-token: write` が要る。

```sh
curl -sS -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://jaeger-mcp-ci.boykush.com" | jq -r .value
```

#### MCP サーバーを増やす

手順は skill `add-mcp-server`（`.apm/skills/add-mcp-server/`）。

#### tunnel の設定

tunnel 本体・route（hostname → Service）・DNS の CNAME はすべて `terraform/cloudflare.tf` にある（remotely-managed tunnel なので、route は Cloudflare 側に置かれた設定を Terraform が書く）。編集するのは `terraform/variables.tf` の `tunnel_routes` だけ。

```hcl
{
  subdomain = "backstage"
  service   = "http://backstage.backstage.svc.cluster.local:7007"
}
```

`service` は **クラスタ内から見た FQDN**。`cloudflared` は別 namespace に居るので短縮名では引けない。catch-all（`http_status:404`）と CNAME は `subdomain` から自動で付く。

zone ID と account ID は `var.domain` から引いている。API token に要る権限は `terraform/providers.tf` の `cloudflare` provider のコメントが持つ。

token は credential なので git に入れず、Parameter Store に書く（→ [クラスタの Secret](#クラスタの-secret)）。tunnel を作り直したときだけやり直す。

```sh
mise exec -- terraform -chdir=terraform output -raw tunnel_token \
  | mise run cluster:secret cloudflared cloudflared-tunnel-token token
```

Secret ができるまで `cloudflared` の Pod は `CreateContainerConfigError` で止まる。

**scraps は Host ヘッダを検証する**（rmcp の DNS リバインディング対策）。既定の許可リストは `localhost` / `127.0.0.1` / `::1` だけなので、公開ホスト名で叩くと 403 `Forbidden: Host header is not allowed` になる。Deployment の `--allowed-host` に公開ホスト名を渡して許可する（scraps v1.2.0 以降）。loopback は残るので port-forward も併用できる。Cloudflare 側の Host Header 書き換えについては AGENTS.md の「MCP サーバー」節。

adi（`adr`）は Host を loopback で受けた接続でしか検証しない（公式 Go SDK の既定と同じ判定）。tunnel からの接続は pod network 経由なので、`--allowed-host` に当たる設定は要らない。

port-forward も従来どおり使える。tunnel を疑うときの切り分けに。

```sh
mise exec -- kubectl -n remote-mcp-server port-forward svc/wiki 1113:1113
```

Image Updater の git write-back には main への push 権限が要る（Argo CD は読むだけなので別の credential）。**PAT では通らない**——main の ruleset のうち push を止めるもの（`boykush/github-management` が張る Require pull request と required check）を bypass できるのは GitHub App だけなので、専用の App を作り、その App id をそれらすべての bypass actor に足す（github-management の ruleset module が付ける）。App に要る権限は Contents: write、install 先はこのリポジトリだけでいい。

credential は Parameter Store に書く（→ [クラスタの Secret](#クラスタの-secret)）。Secret `argocd/image-updater-git-creds` の3つの key がそのまま App の3つの値で、**private key も GitHub には置かない**。この App の鍵だけ KMS に入らない理由は [GitHub App の秘密鍵（AWS KMS）](#github-app-の秘密鍵aws-kms)。

```sh
echo 4703313 | mise run cluster:secret argocd image-updater-git-creds githubAppID
echo <Installation ID> | mise run cluster:secret argocd image-updater-git-creds githubAppInstallationID
mise run cluster:secret argocd image-updater-git-creds githubAppPrivateKey < <app>.private-key.pem
```

`githubAppID` に入れるのは **App ID**（数値）。GitHub は JWT の `iss` に Client ID を使うことを推奨しているが、Image Updater は base 10 で parse するので Client ID を入れると `invalid value in field githubAppID` で落ちる。ruleset の bypass actor に足す `actor_id` も同じ App ID。

Secret ができるまで Image Updater は新しい digest を見つけても書き戻せない。Pod は落ちず、`could not get creds for repo` がログに出続けるだけなので、digest が動かないときはまずここを見る。

### クラスタの Secret

クラスタの Secret は kubectl で手作りしない。値は Parameter Store に置き、External Secrets Operator（`applications/external-secrets.yaml`）がクラスタの Secret に同期する。**どの parameter がどの Secret になるかは、使う app の隣の `ExternalSecret` が持つ**ので、ここには写さない。

値を入れる・替えるのは parameter を書くだけで、手元に DO の PAT は要らない。クラスタを作り直したときも operator が全部戻す。

```sh
mise exec -- aws login
mise run cluster:secret <namespace> <secret> <key>   # 値を貼って Ctrl-D
```

反映は `ExternalSecret` の `refreshInterval` ごと。Secret を env で読んでいる Pod は、Secret が変わっても再起動するまで古い値のまま動く。

Secret を増やすときは、app の directory に `ExternalSecret` を足し、同じ名前の parameter を書く。operator が読めるのは `terraform/variables.tf` の `cluster_secrets_parameter_path` の下だけ。

#### operator 自身の access key

**operator は IAM の access key で Parameter Store を読む**——この基盤で唯一の長命な AWS の鍵。role にできない理由は AGENTS.md の「DOKS の勘所」。鍵が開くのは上の path の読み取りだけ（`terraform/aws.tf`）。

この鍵だけは operator が自分で取れないので、Actions の **External Secrets Credential**（`workflow_dispatch`）が GitHub の OIDC で読んでクラスタに入れる。鍵を作るのも入れ替えるのも同じ2行で、クラスタを作り直したときは2行目だけ。

```sh
mise run external-secrets:key
gh workflow run external-secrets-credential.yml
```

`external-secrets:key` は古い鍵を消してから新しい鍵を作る。workflow が届けるまで operator は同期できないが、クラスタにある Secret はそのまま残るので、止まるのは更新だけ。鍵の値は端末に出ない。

### UI

`https://argocd.boykush.com` で開く。Backstage と同じく Access（`terraform/access.tf`）の GitHub ログインだけで入れる。Argo CD 自身のログインは無く、Access を通った相手はそのまま admin になる（anonymous を admin にしている）。

port-forward でも入れる。tunnel を疑うときの切り分けに。TLS は Cloudflare で終わらせて argocd-server は平文で待っている（`argocd/kustomization.yaml` の `server.insecure`）ので、`http://localhost:8080` を開く。

```sh
mise exec -- kubectl -n argocd port-forward svc/argocd-server 8080:80
```

### Backstage

[boykush/github-management](https://github.com/boykush/github-management) の `catalog/`（repo をまたいで作用する関係のカタログ）を見る Backstage。公式 image（`ghcr.io/backstage/backstage`）をそのまま使い、この repo が持つのは manifest と、image 既定の設定に重ねる `applications/backstage/app-config.yaml` だけ。画面に何を出すか（Home のリンク集・Catalog Graph）は catalog と同じ image に入って届き、その後ろに重なる。

`https://backstage.boykush.com` で開く。tunnel で公開しているが、前段の **Cloudflare Access が owner のメールアドレスしか通さない**（`terraform/access.tf`）。ログインは GitHub で、Access を通った後の Backstage には guest で入る。

Access を外してはいけない。Backstage は guest で誰でもサインインでき permission も allow-all なので、素のまま公開すると、scaffolder の試し実行など guest に許した操作を誰でも動かせてしまう。

例外は path が1つだけある。coding agent が catalog を引く MCP サーバーで、`https://backstage.boykush.com/api/mcp-actions/v1/catalog` を Access の bypass policy で無記名のまま通す。出しているのは read-only の catalog action（`catalog:query-catalog-entities` など）に絞った named server で、絞っていない既定の server（`/api/mcp-actions/v1`。常に全 action を出す）は Access の内側に残る。Access は具体的な path を先に評価するので、この2つは共存する。

```sh
claude mcp add --transport http catalog https://backstage.boykush.com/api/mcp-actions/v1/catalog
```

Access を抜けただけでは足りない。**Backstage は action を無記名では実行しない**——auth policy とは別のチェックで、設定からは外せない（`tools/list` は通るのに `tools/call` が `NotAllowedError` になる）。そこで `backend.auth.externalAccess` に static token を置き、Cloudflare の Transform Rule が同じ path にだけ `Authorization: Bearer` を足す。エージェント側は何も持たない。

**この値は秘密ではない。** Backstage が要求するのは「空白を含まない8文字以上」だけで、一致すれば `subject` がそのまま principal になる——鍵ではなく名札で、通せるのは read-only の catalog action だけ。だから `terraform/access.tf` と `applications/backstage/app-config.yaml` に literal で書いてある（**両方を揃える**。ズレたら 401 で、開きっぱなしにはならない）。秘密にすると、同期と rotate と「Secret が無いと Pod が上がらない」依存を抱える代わりに守れるのは Access の path を誤って広げた場合だけで、割に合わない。

裏を返すと、**境界は Access の path 1本**しかない。`terraform/access.tf` の `domain` と `destinations` を触る変更はそこが全てなので、レビューではそこを見る。

- 通すメールアドレスは public repo に置かず、secret `ACCESS_OWNER_EMAIL` から `TF_VAR_access_owner_email` で渡す。照合する相手は GitHub がログインしたアカウントについて返すアドレスなので、そのアドレスにしておく（Zero Trust ダッシュボードで GitHub のログイン方法の Test を押すと見られる）。
- GitHub ログインは owner の OAuth App を通る。Settings → Developer settings → OAuth Apps で手で作り、Homepage URL に `https://boykush-zt.cloudflareaccess.com`、Authorization callback URL に `https://boykush-zt.cloudflareaccess.com/cdn-cgi/access/callback` を入れる。Client ID は `terraform/access.tf` に書き、Client secret は secret `ACCESS_GITHUB_CLIENT_SECRET` から `TF_VAR_access_github_client_secret` で渡す。
- Client secret を替えるときは、OAuth App に新しい secret を足して `ACCESS_GITHUB_CLIENT_SECRET` を差し替え、次の apply で Cloudflare に届いてから古い方を消す。
- base URL が公開ホスト名なので、port-forward では画面が動かない（API の切り分けにだけ使える）。

catalog は github-management が build する image（`ghcr.io/boykush/github-management-catalog`、public）から、init container が `/catalog` にコピーして読ませる。GitHub の credential は要らない。catalog が更新されると、Image Updater が新しい digest を `applications/backstage/kustomization.yaml` に書き戻し（何を追うかは `applications/backstage/imageupdater.yaml`）、Pod が作り直されて読み直す。

entity のページには Kubernetes タブがあり、その repo の workload の状態（Deployment・pod・CronJob など）が出る。どの workload を出すかは catalog 側の annotation が `app.kubernetes.io/part-of` の label で選び、その label はこの repo の各アプリの `kustomization.yaml` が付ける。クラスタは Pod の ServiceAccount で読み、Headlamp と同じく誰が開いてもその権限になる。何を読めるかは `applications/backstage/rbac.yaml` が持ち、cloudflared 以外からは届かないようにしてある（`applications/backstage/networkpolicy.yaml`）。

### Headlamp

node の利用状況——CPU・メモリの実測と、それを食っている workload——を見る [Headlamp](https://headlamp.dev)。`https://headlamp.boykush.com` で開く。Backstage や Argo CD と同じく Access（`terraform/access.tf`）の GitHub ログインだけで入れ、Headlamp 自身のログインは無い。

Headlamp は本来、開いた人に ServiceAccount の token を貼らせる。ここではそれを止め、**誰が開いても Pod の ServiceAccount として読む**ようにしてある（`applications/headlamp/deployment.yaml`）。画面に出るのはその ServiceAccount が読めるものだけで、何を読めるかは `applications/headlamp/rbac.yaml` が持つ。権限の外のページはエラーになる。

**Argo CD とは見るものが違う。** Argo CD は何を宣言し、同期したかを見せる。Headlamp は実際に何が動き、どれだけ使っているかを見せる——実測値と、Argo CD の管理外にある `kube-system` の workload はこちらにしか出ない。ConfigMap や NetworkPolicy のような宣言の側は Headlamp に読ませていない。

実測値の出どころは metrics-server（`applications/metrics-server/`）。DOKS には入っていないので、これが無いと Headlamp の利用率は空になり、`kubectl top` も動かない。

port-forward でも入れる。tunnel を疑うときの切り分けに。`http://localhost:4466` を開く。

```sh
mise exec -- kubectl -n headlamp port-forward svc/headlamp 4466:4466
```

### finlake

[boykush/finlake](https://github.com/boykush/finlake) のお金まわりのデータ。オーナーがマネーフォワード ME の画面から落とした CSV を R2 の raw 層に置き、クラスタの CronJob `sync`（`applications/finlake/sync-cronjob.yaml`、namespace `finlake`）がそれを product の明細に変換する。置き方の決まり（フォルダ名、1か月に1ファイル）は finlake の README の「データレイク」が持つ。結果は同じ namespace の Deployment `mcp`（`applications/finlake/mcp-deployment.yaml`）が MCP で配る（→ [MCP](#mcp)）。

データの置き場は Cloudflare R2 のバケット `finlake`（`terraform/r2.tf`）。量が月に KB 単位で無料枠に収まり、作るのに要るのが既存の Cloudflare の API トークンだけなので、DO Spaces（月 $5 の定額、CI に全バケットを触れる S3 キーが要る）ではなくこちらにした。

`sync` が走るのは月初の間だけ（schedule は manifest）。それ以外の日に置いたとき、置いてすぐ反映したいときは手で流す。変換が要る月が無ければ何もしないので、何度流してもよい。

```sh
mise exec -- kubectl -n finlake create job --from=cronjob/sync "sync-manual-$(date +%s)"
mise exec -- kubectl -n finlake logs -f job/<上で出た名前>
```

置き間違い（月のフォルダに CSV が2つ、明細がフォルダの月と違う、フォルダ名が `month=YYYY-MM` でない）があると、その月を変換せずに Job が失敗する。ログに月と理由が出るので、R2 の側を直して流し直す。

#### Secret

`sync` と `mcp` が R2 に届くためのトークンは commit せず、Parameter Store に書く（→ [クラスタの Secret](#クラスタの-secret)）。R2 のエンドポイントに入る account id は git のどこにも書かれていない（Terraform が domain から引く）ので、エンドポイントもトークンと一緒に Secret に置く。

ダッシュボードの R2 → Manage API tokens で、権限 Object Read & Write、対象をバケット `finlake` だけに絞って作る。出てくる Access Key ID / Secret Access Key と、S3 のエンドポイント（`https://` を除いた `<account_id>.r2.cloudflarestorage.com`）を入れる。

```sh
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_ENDPOINT
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_ACCESS_KEY_ID
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_SECRET_ACCESS_KEY
```

Secret ができるまで `sync` の Pod は `CreateContainerConfigError` で止まる。

`mcp` も同じ Secret で lake を読む。Secret を env で読むので、値を替えたら Pod を作り直す。

```sh
mise exec -- kubectl -n finlake rollout restart deployment/mcp
```

#### MCP

`https://finlake-mcp.boykush.com/mcp`。家計は非公開で、finlake の MCP サーバー自身はログインを持たないので、認証は前段が担う（→ [非公開の MCP の認証](#非公開の-mcp-の認証)）。エージェントは初回だけ `/mcp` から認証する。tool の一覧とクライアント側の設定は finlake の README が持つ。

クラスタ内では NetworkPolicy（`applications/finlake/networkpolicy.yaml`）が agentgateway 以外を止める。

port-forward でも入れる。tunnel を疑うときの切り分けに。

```sh
mise exec -- kubectl -n finlake port-forward svc/mcp 8080:8080
```

### OpenTelemetry Collector と Jaeger

workload のテレメトリーは OpenTelemetry Collector（`applications/otel-collector/`）が受け、後段の Jaeger（`applications/jaeger/`）へ流す。**workload が知るのは Collector の Service だけ**で、何をどこへ流すかは `applications/otel-collector/config.yaml` の `pipelines` と `exporters` が持つ。後段を替えるときに触るのはそこだけで、workload 側は変わらない。

送る側は、OTLP の送り先を Collector の Service に向ける（ホスト名とポートは `applications/otel-collector/service.yaml`）。Jaeger を直接指しても届かない——Collector 以外からの書き込みは NetworkPolicy が落とす。

Jaeger の UI は `https://jaeger.boykush.com` で開く。Backstage や Argo CD と同じく Access（`terraform/access.tf`）の GitHub ログインだけで入れ、Jaeger 自身のログインは無い。

エージェントからは MCP でトレースを引ける。Jaeger は UI と同じポートの `/api/ai/mcp/` に出すが、MCP だけに掛けられる認証を持たないので、外へは agentgateway が `https://jaeger-mcp.boykush.com/mcp` として出す（→ [非公開の MCP の認証](#非公開の-mcp-の認証)）。UI のホスト名からは MCP に入れない。

この repo で動くエージェントの接続先は `.mcp.json` にあり、初回だけ `/mcp` から認証する。

port-forward でも入れる。tunnel を疑うときの切り分けに。UI は `http://localhost:16686`、MCP はその `/api/ai/mcp/`。

```sh
mise exec -- kubectl -n jaeger port-forward svc/jaeger 16686:16686
```

トレースは Jaeger に内蔵の Badger が DigitalOcean の volume（`applications/jaeger/pvc.yaml`）に書くので、夜間停止で node が作り直されても残る。保持期間は `applications/jaeger/config.yaml` の `ttl`。

## Claude Code Actions のトークン（AWS）

`boykush` は **User アカウントなので organization secret が無い**。Claude Code Actions を動かす repo ごとに `CLAUDE_CODE_OAUTH_TOKEN` を置くしかなく、実際 wiki は OAuth トークン、scraps は API キーと割れていた。トークンを AWS に1つ置き、**各 repo はその run の OIDC で読む**ことにして、repo 側から秘密を無くす。

トークンの parameter と、それを読む role・CI が apply に使う role は `terraform/aws.tf`（parameter の名前は `terraform/variables.tf` の `claude_code_parameter_name`）が持つ。各 repo が呼ぶ composite action は boykush/workflows の `.github/actions/claude-code-token/`。

費用は実質 **$0**——standard parameter は保管も API 呼び出しも無料で、IAM と STS にも課金は無い。SecureString の復号で KMS の request が立つが、既定の `aws/ssm` キーに月額は無く、$0.03/10,000 なので月数百回なら $0.01 に届かない。

**Terraform はトークンを持たない**（理由は AGENTS.md の「AWS の認証情報」）。parameter だけは CLI（`mise run claude:token`）で書く。

### bootstrap（初回のみ）

CI はここで作る role を assume して動くので、**その role を作る最初の apply だけローカルで行う**。クラスタの初回 bootstrap と同じ例外で、merge する前に、この変更が載っているブランチで実行する。

**1. コンソールの認証情報で CLI にログインする。** root に MFA（パスキー）を付ける。**access key は作らない**——root のものは AWS 自身が禁じているし、IAM ユーザーのものも要らない。

`aws login` は**コンソールのサインインをそのまま使って最大12時間の一時認証情報を取る**（CLI 2.32.0 以降）。Identity Center も Organizations も access key も要らず、root ならば追加の権限も要らない（IAM ユーザーで使うなら `SignInLocalDevelopmentAccess` を付ける）。

```sh
mise exec -- aws login
```

ブラウザが開くのでパスキーで認証する。

**profile とリージョンは repo に閉じている。** `aws login` は profile を1つ書くので、`mise.toml` の `[env]` が `AWS_CONFIG_FILE` を `.aws/config` に、`AWS_REGION` を `ap-northeast-1` に向けている——マシン全体の `~/.aws/config` には何も書かれず、リージョンを対話で訊かれることもない。書かれる中身は識別子だけだが、ログインし直せば再生成される生成物なので `.aws/` は commit しない。

```
[default]
login_session = arn:aws:iam::509266991346:root
region = ap-northeast-1
```

**profile 名は `default` で、`AWS_PROFILE` は `[env]` に置かない**（理由は `mise.toml` の `[env]` のコメントと AGENTS.md の「Backend / 認証」）。名前付き profile を指していると、CI の terraform が `.aws/config` の無い runner で `failed to get shared config profile` と落ちる。

一時認証情報の方は `~/.aws/login/cache/` に入る（`AWS_LOGIN_CACHE_DIRECTORY` で移せるが、12時間で失効するものなので既定のまま）。

**IAM Identity Center（SSO）は使っていない。** 単一アカウントで有効化すると account instance になり、permission set も AWS アカウントの割り当ても持てない——CLI 用の認証情報はそこからは出てこない。組織インスタンスにするには AWS Organizations が要るが、`aws login` で足りるので構えを取っていない。

**2. 変数を渡す。** root module は1つなので、AWS だけ足すときも宣言済みの変数には値が要る。**実値を入れること**——次の手順では使われないが、同じシェルで後から full apply すると Access がその値で書き換わる。

```sh
export TF_VAR_access_owner_email=...
export TF_VAR_access_github_client_secret=...
```

**AWS は何も export しない。** aws provider は `login_session` を解釈するので、`AWS_PROFILE` が指すプロファイルからそのまま認証する。`aws configure export-credentials` で環境変数に固める手もあるが、**それが返すのは15分で切れる認証情報**で、作業の途中で期限が切れるうえ、env の認証情報は profile より優先されるので復旧の邪魔になる。

```sh
mise exec -- aws sts get-caller-identity
```

`509266991346` が返れば通っている。

**3. AWS のリソースだけ apply する。** **DO と Cloudflare の認証情報は要らない**——この5つはどちらにも依存していないので、`-target` で絞るとそれらの API は呼ばれず、refresh も走らない。素の `apply` は state 全体を触りにいくので、この段階では使わない。

```sh
mise exec -- terraform -chdir=terraform apply \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_role.claude_code \
  -target=aws_iam_role_policy.claude_code \
  -target=aws_iam_role.terraform \
  -target=aws_iam_role_policy.terraform
```

`Plan: 5 to add, 0 to change, 0 to destroy.` を確かめてから `yes`。`-target` には「通常運用向けではない」という警告が出るが、bootstrap はまさにその例外で、**残りは merge 後に CI が full apply で揃える**。

**4. トークンを入れる。** `claude setup-token` の出力を貼って Ctrl-D。確認は値を出さずに version だけ見る。**端末幅で折り返された値をコピーすると改行が混ざる**ので、タスク側で空白を落として `sk-ant-oat` で始まることを検証している——改行が残ったまま保存されると、読み出し側で `::add-mask::` が行単位に効かず、**2行目が CI のログに出る**。

```sh
mise run claude:token
mise exec -- aws ssm get-parameter --region ap-northeast-1 --name /claude-code/oauth-token \
  --query 'Parameter.{Version:Version,Type:Type}'
```

**5. セッションを終了する。**

```sh
mise exec -- aws logout
```

長命の鍵をどこにも作っていないので、消すものは無い。次に手元から触るとき——トークンの入れ替えや、信頼を壊したときの復旧 apply——は `aws login` をやり直すだけ。

**3 が済むまで PR の `terraform plan` は落ちる**（role がまだ無いため）。merge を止めるのは zizmor だけなので、plan の赤は無視して進められる。merge 後の push で初めて CI が `github-actions-terraform` として apply するので、**権限の過不足が出るとしたらそこ**——`iam:*` を3つの ARN に絞ってあるので、resource 指定を受け付けない IAM アクションがあれば `AccessDenied` で分かる。

経路全体が通ったことを確かめられるのは、トークンを読む workflow（今は ai-review を入れた repo の PR の review）を1回動かしたときだけ。OIDC は手元から再現できない。

**role の ARN は repo に直接書いてある**（この repo の `.github/workflows/terraform.yml` と、boykush/workflows の `.github/actions/claude-code-token/action.yml`）。account id が public repo に載るのは承知の上で——AWS 自身が account id を secret ではないとしており、ARN 単体では OIDC の `sub` が一致しない限り何もできない。variable に逃がすと呼び出し側の repo ごとに set して回ることになり、秘密を1箇所に寄せた意味が薄れる。

### ローテーション

`mise exec -- aws login` してから `mise run claude:token` を流すだけ。**`claude setup-token` が出すトークンの有効期間は1年**なので、定期の入れ替えはその周期。漏洩を疑ったときは即座に同じ手順で差し替える。**repo ごとに `gh secret set` して回る必要が無い**のがこの構成の実利で、現実的に回せる頻度が上がる。

### repo を足す

手順は skill `add-claude-code-repo`（`.apm/skills/add-claude-code-repo/`）。`sub` クレームの2形式は AGENTS.md の「AWS の認証情報」。

### 限界

**runner の上にはトークンが載る**。repo secret と比べて消えるのは「GitHub 側に長命な秘密が残ること」「ローテーションが repo の数だけ要ること」で、run 中の漏洩リスクは変わらない——[OIDC でも残る漏洩リスク](https://blog.flatt.tech/entry/2026-github-actions-security-part3)が言う通り。

緩和は2つだけ効かせてある。composite action は `output-env-credentials: false` で **AWS の認証情報を job の環境に置かず**、読み取り step にだけ渡す。role が読めるのは parameter 1本だけで、他の AWS 権限は持たない。**Claude の step が任意コードを実行する以上、そこから先は分離できない**——認証 step と実行 step を別 job にする定石が、この workload では使えない。

構造的に無くすなら [Claude 自身の WIF](https://platform.claude.com/docs/en/manage-claude/workload-identity-federation)（`anthropic_federation_rule_id`）で、トークンそのものが不要になる。ただし organization の service account として **API 従量課金**になり、Max のシートは使えない。

## GitHub App の秘密鍵（AWS KMS）

**GitHub App の private key には期限が無い**。repo secret に置いた鍵は、漏れてから App に登録したままにしている限り、いつまでもインストールトークンを発行できる。鍵を **AWS KMS に取り出せない形で入れ**、JWT の署名だけを KMS に任せることにして、GitHub 側から鍵を消した。workflow が持つのは「署名できること」で、それは IAM で剥がせる。

差し替え先は [`suzuki-shunsuke/create-github-app-token-aws-kms`](https://github.com/suzuki-shunsuke/create-github-app-token-aws-kms)。`actions/create-github-app-token` と入出力が揃っていて、`private-key` が `kms-key-id` に替わる。使う側が直接呼ぶのではなく、[boykush/workflows](https://github.com/boykush/workflows) の `github-app-token` action を通す——alias も role の ARN も App 名から決まるので、そこで組み立てて渡している。

どの App があり、どの repo が署名してよいかは `terraform/variables.tf` の `github_apps` が持つ。KMS の alias（`alias/github-app-<name>`）も署名する role もその名前から決まるので、ここには写さない。`image-updater` だけはその list に無く、鍵の置き場も違う——理由は下記。

App の id（App ID / Client ID）はここに書かない。台帳は github-management の catalog（`resource:<app>-app` の annotation）で、run から引く写しを `github-app-token` が持つ。

**`image-updater` だけ KMS に入らない。** Image Updater はクラスタの中で自分で JWT に署名するので、渡すものが鍵そのものになる——KMS は鍵を返さないので、入れても使えない。この1つは SecureString（既定の `aws/ssm` キー）に置き、External Secrets Operator がクラスタの Secret にする（→ [クラスタの Secret](#クラスタの-secret)）。GitHub 側から鍵が消える点は同じで、違うのは鍵が AWS から出るかどうかだけ。

費用は **key 1本 $1/月**（本数は `github_apps` の数）。署名は RSA 2048 の request なので $0.03/10,000——Renovate を毎時回しても月 $0.01 に届かない。Parameter Store 側はこれまでどおり $0。

**鍵は Terraform を通らない**・**role は App ごとに分ける**・**CI は key を作れるが使えない**、の3つがこの構成の要で、理由は AGENTS.md の「AWS の認証情報」にある。

### App を入れる・鍵を入れ替える

App を1つ入れる手順と鍵を入れ替える手順は skill `add-github-app`（`.apm/skills/add-github-app/`）。

### 監査

`kms:Sign` は CloudTrail に残り、**セッション名が `gha-<run id>-<run attempt>`** なので、どの run がトークンを取ったかまで辿れる。GitHub の監査ログはトークンの行いを App にしか紐付けないので、run を名指しできるのは AWS 側だけ。

### 失敗の見え方

| 症状 | 原因 |
| --- | --- |
| action が `KMSInvalidStateException` | key が `PendingImport` のまま（material を入れていない） |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | その repo が `github_apps` の `repositories` に無い。`main_only` の App なら、main 以外の run から来た（実際に届いた `sub` は CloudTrail で見る） |
| action が入力エラーで落ちる | `permission-*` が1つも無い |

## Toolchain

Terraform / doctl / kubectl / AWS CLI を [mise](https://mise.jdx.dev/) で固定（`mise.toml`）。

```sh
mise install   # mise.toml のバージョンで導入
```

個々の tool を固定している理由は `mise.toml` のコメント。

## Local development

state は HCP Terraform（`cloud {}` backend）にあるので、`init` 以降は認証が要る。

```sh
mise install                            # toolchain を導入
mise run tf:login                       # HCP backend 認証（一度だけ）
doctl auth init                         # DO の PAT を入力（~/.config/doctl/config.yaml に保存）
export DIGITALOCEAN_ACCESS_TOKEN=...    # provider 用（doctl と同じ変数名）
export TF_VAR_access_owner_email=...    # Access が通すアドレス（public repo に置かないため変数で渡す）
export TF_VAR_access_github_client_secret=...  # Access の GitHub ログイン（無ければダミーでよい。plan に差分が1つ出るだけ）

cd terraform
mise exec -- terraform init
mise exec -- terraform plan
```

- `terraform fmt` は認証不要。
- **`apply` はローカルで実行しない**——main への push で CI が行う。クラスタの初回 bootstrap だけは例外的にローカルから apply した。
- kubeconfig は `mise run k8s:kubeconfig`（`doctl kubernetes cluster kubeconfig save`）で取る。context 名は `do-sgp1-boykush-cluster`。

## CI（`.github/workflows/terraform.yml`）

PR で `terraform plan`（tfcmt がコメント）、main への push で `terraform apply`。トリガと、各 step に渡す secret は `.github/workflows/terraform.yml` が持つ。

**External Secrets Credential**（`workflow_dispatch`）は External Secrets Operator の access key を Secret `external-secrets/parameter-store-credentials` として適用する（→ [クラスタの Secret](#クラスタの-secret)）。Secret を書くので push では起動しない。鍵は repo secret ではなく Parameter Store から OIDC で読む（`github-actions-external-secrets` role）。

HCP の workspace は Execution Mode = **Local**（`terraform/versions.tf` のコメント）。

## 夜間停止（`node-pool-park.yml` / `node-pool-resume.yml`）

worker node を毎晩 0 台に落として朝に戻す。node は止めている間は課金されない（止めても課金が続くのは Jaeger の volume だけ → [費用](#費用)）。

park は node pool を 0 に、resume は 1 に戻して配信が戻るまで待ち、**Node Pool Status**（`node-pool-status.yml`、dispatch のみ）は読むだけ。時刻は各 workflow の `cron` と、その隣のコメント（JST と選んだ理由）が持つ。

やることが違う（resume だけが復帰を待つ）ので workflow を分けてある。どちらも `workflow_dispatch` を持つので、手動実行がそのまま動作確認と復旧手段になる。`concurrency` group は共通（`node-pool`）で、park と resume は重ならない。

- **停止中は tunnel の先がすべて落ちる**（`terraform/variables.tf` の `tunnel_routes`。catalog の MCP も含む）。cloudflared ごと消えるので Cloudflare が 530 を返す。
- resume の gate は、`node-pool-resume.yml` が待つ rollout **だけ**（tunnel から MCP サーバーまでの経路に居るもの）。ノードの Ready は見ない——削除中のノードも Ready を返すので、park 直後の resume がそれを掴んで素通りする。
- 実測値。10 時に使える状態にするための逆算がこれ。

| 計測 | 値 |
| --- | --- |
| park 投入 → endpoint 停止 | 約 25 秒 |
| resume 投入 → 配信復帰（ノード破棄済みの状態から） | **11 分 17 秒** |
| 同、2026-09-14 の定期実行 | 3 分 41 秒 |
| rollout の予算 | 20 分 |

- **GitHub の schedule は定刻に来ない。実測で park が 3 時間 02 分、resume が 1 時間 48 分遅れた**（2026-09-13、Actions は全系正常でインシデント無し）。分を `:37` にしてあるのは毎時の頭がこの遅延の温床だから——ドキュメントが言う "high load times include the start of every hour" は分の話で、タイムゾーンに依らない。効くかどうかは数日ぶんの実績を見ないと判断できない。
- 06:37 起床なのは、この 3 時間 02 分に rollout 予算 20 分を足しても 10 時に間に合わせるため。締切が 10 時なのは、直近 72 日の commit で 10:10 より前に着手した日が 1 割だったから。park が 01:37 なのは同じデータの逆側で、これより遅くまで作業した日が commit のあった 36 日中 1 日だったため。
- **park が 5 時間以上遅れると resume を追い越す**。`concurrency` group が直列化するので park が後に回り、日中ずっと停止したままになる。実測最大 3 時間 02 分に対して余裕は 2 時間弱しかない。
- **`count 0` は desired state。到達後もしばらく node が列挙され続ける**ので、park 直後の `Count 0` は課金が止まった証拠にならない。判断材料はノード名で、park を挟むと別名のノードとして戻る（`default-3fthnc` → `default-3ft41g`）。droplet が作り直されている、つまり課金が切れている。
- Status の droplet 一覧は CI の token に droplet read が無いので 403 になる。落とさず続行する。見たければ token の scope を広げる。
- 止めたくない日は Actions の UI から workflow を disable する。
- schedule は repo が 60 日無活動だと自動停止するが、Image Updater の commit が入るので実質起きない。

## 費用

クラスタで課金されるのは worker node と Jaeger の volume で、control plane と VPC は無料。volume は **$0.10/GiB・月**（サイズは `applications/jaeger/pvc.yaml`）で、node を止めていても課金が続く。MCP サーバーの公開に Cloudflare Tunnel を使っているのも、Load Balancer（$12/月〜）を増やさないため。AWS 側は GitHub App の鍵を持つ KMS の key が **1本 $1/月**（本数は `github_apps` の数）で、それ以外——IAM・STS・standard parameter——は保管も呼び出しも無料。finlake の R2 は無料枠（保存 10 GB/月、書き込み 100 万回・読み取り 1000 万回/月、転送は無料）に収まるので $0。

node は秒課金（$0.03571/時）だが **月 672 時間（28 日）で頭打ち**になる。連続稼働なら毎月この上限に当たるので $24/月で一定、裏を返せば月 48 時間までの停止は請求に効かない。

| 稼働 | 課金時間 | ノード代 |
| --- | --- | --- |
| 連続（30 日） | 672（上限） | $24.00 |
| 夜間停止 5.0h/日（30 日） | 570 | $20.35 |
| 同、park が毎晩 3 時間遅れた月 | 660 | $23.57 |

停止が 5 時間しか取れないのは、夜の作業が 01:00 過ぎまで伸びる一方で朝の締切が 10 時だから。そこに最大 3 時間の schedule 遅延が乗るので、**節約は遅延次第で $3.65 から $0.43 まで振れる**。窓を広げるには GitHub の schedule 以外の発火元（Cloudflare Workers の Cron Trigger から `workflow_dispatch` を叩くなど）が要る。

outbound 転送は月 4,000 GiB まで無料で、超過分が $0.01/GiB——従量なのはここだけ。使わない期間は `terraform destroy` で完全に止められる——`destroy_all_associated_resources = true` なので、クラスタが作った LoadBalancer / volume も一緒に消える。**ただし root module は1つなので、素の destroy は KMS の key まで消しにいく**（= App の鍵を失う）。止めたいのはノード代なので、`-target=digitalocean_kubernetes_cluster.this` で絞るか、夜間停止をそのまま使う。
