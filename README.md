# infrastructure-as-code

boykush の個人アプリケーションを載せる Kubernetes 基盤のリポジトリ。クラスタ（DigitalOcean Kubernetes / DOKS）を Terraform で作り、その上のアプリケーションは Argo CD で GitOps デプロイする。

## クラスタ

| 項目 | 値 | 補足 |
| --- | --- | --- |
| region | `sgp1`（Singapore） | DO に東京リージョンは無く、日本から最も近い |
| Kubernetes | `1.36` 系 | patch は DO の auto-upgrade 任せ。minor は `kubernetes_version_prefix` で固定 |
| node pool | `s-2vcpu-4gb` × 1 | 連続稼働で $24/月。Argo CD + DOKS の system pod が載る実質の下限。夜間は 0 台に落とす |
| control plane | 非 HA | 無料。HA にすると +$40/月 |
| VPC | 専用 / `10.10.0.0/16` | 無料。`ip_range` は後から変更できない |
| maintenance | 日曜 04:00 UTC | = 日曜 13:00 JST。夜間停止の時間帯を避けてある |

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

MCP サーバーは `applications/remote-mcp-server/<name>/` にまとめて置き、1つの Application（namespace `remote-mcp-server`）で同期する。どのサーバーがどの repo の何を配っているかは catalog が持つ（`type: mcp` の API と、それを provides する component）。イメージは各アプリ側の CI が GHCR へ push し、新しい digest は Image Updater が `applications/remote-mcp-server/kustomization.yaml` に書き戻す。何を追うかは `applications/remote-mcp-server/imageupdater.yaml`（`ImageUpdater` CR）で決める——v1.x は Application の annotation を読まない。

公開は Cloudflare Tunnel 経由（`applications/cloudflared/`）。`cloudflared` がクラスタ内から Cloudflare へ張った接続を traffic が下ってくるので、Service は ClusterIP のままで、ノードの public IP には何も開かない。DigitalOcean の Load Balancer（$12/月〜）が要らないのはこのため。TLS と公開ホスト名は Cloudflare 側が持つ。**tunnel は1本で全ホスト名を捌く**ので、サーバーが増えても `cloudflared` は増えない。

この repo が持つのは公開エンドポイントまで（URL と MCP サーバー名は catalog の各 API の `definition`）。**エージェントに使わせる設定は担当外**で、[boykush/ai-plugins](https://github.com/boykush/ai-plugins) が apm package として配る。

catalog を引く MCP サーバーは Backstage が出すので、この Application には居ない（→ [Backstage](#backstage)）。ホスト名も取らず、`backstage.<ドメイン>` の path で分かれる。

エンドポイントのパスはどのサーバーも `/mcp` 固定なので、サーバーを区別できるのはホスト名だけ。`<name>-mcp.<ドメイン>` で並べる。Cloudflare の Universal SSL が覆うのは1階層目までなので、`<name>.mcp.<ドメイン>` のような2階層は使わない。

**これらの MCP は無認証で公開している**——wiki も adr も内容は元から公開で、scraps と adi の MCP はどちらも読み取り専用なので、前段に認証を置いていない。絞りたくなったら Cloudflare 側で rate limit や Access を被せられる（クラスタ側の manifest は変更不要）。

#### MCP サーバーを増やす

1. `applications/remote-mcp-server/<name>/` に Deployment / Service / kustomization を置く
2. `applications/remote-mcp-server/kustomization.yaml` の `resources` と `images` に1行ずつ足す
3. `applications/remote-mcp-server/imageupdater.yaml` の `images` に `alias` / `imageName` / `updateStrategy` を1つ足す
4. `terraform/variables.tf` の `tunnel_routes` に `subdomain` と `service` を1つ足す
5. [boykush/github-management](https://github.com/boykush/github-management) の catalog に API を足し、出す repo の component から `providesApis` を張る（書き方は `catalog/apis.yaml` の先頭）

#### tunnel の設定

tunnel 本体・route（hostname → Service）・DNS の CNAME はすべて `terraform/cloudflare.tf` にある（remotely-managed tunnel なので、route は Cloudflare 側に置かれた設定を Terraform が書く）。編集するのは `terraform/variables.tf` の `tunnel_routes` だけ。

```hcl
{
  subdomain = "wiki-mcp"
  service   = "http://wiki.remote-mcp-server.svc.cluster.local:1113"
}
```

`service` は **クラスタ内から見た FQDN**。`cloudflared` は別 namespace に居るので短縮名では引けない。catch-all（`http_status:404`）と CNAME は `subdomain` から自動で付く。

zone ID と account ID は書かず `var.domain` から引いている（public repo に識別子を置かないため）。API token に要る権限は Account: Cloudflare Tunnel (Edit) / Zone: DNS (Edit) / Zone: Zone (Read) / Zone: Transform Rules (Edit)、Access（`terraform/access.tf`）のために Account: Access: Apps / Access: Policies / Access: Identity Providers（いずれも Write）、finlake の R2 バケットのために Account: Workers R2 Storage (Edit)。

token は credential なので git に入れず手元で Secret にする。tunnel を作り直したときだけやり直す。

```sh
mise exec -- kubectl -n cloudflared create secret generic cloudflared-tunnel-token \
  --from-literal=token="$(mise exec -- terraform -chdir=terraform output -raw tunnel_token)"
```

Secret ができるまで `cloudflared` の Pod は `CreateContainerConfigError` で止まる。

**scraps は Host ヘッダを検証する**（rmcp の DNS リバインディング対策）。既定の許可リストは `localhost` / `127.0.0.1` / `::1` だけなので、公開ホスト名で叩くと 403 `Forbidden: Host header is not allowed` になる。Deployment の `--allowed-host` に公開ホスト名を渡して許可する（scraps v1.2.0 以降）。loopback は残るので port-forward も併用できる。**Cloudflare 側で HTTP Host Header を書き換える設定は不要**——入っていたら外す。

adi（`adr`）は Host を loopback で受けた接続でしか検証しない（公式 Go SDK の既定と同じ判定）。tunnel からの接続は pod network 経由なので、`--allowed-host` に当たる設定は要らない。

port-forward も従来どおり使える。tunnel を疑うときの切り分けに。

```sh
mise exec -- kubectl -n remote-mcp-server port-forward svc/wiki 1113:1113
```

Image Updater の git write-back には main への push 権限が要る（Argo CD は読むだけなので別の credential）。**PAT では通らない**——main の ruleset のうち push を止めるもの（`boykush/github-management` が張る Require pull request と required check）を bypass できるのは GitHub App だけなので、専用の App を作り、その App id をそれらすべての bypass actor に足す（github-management の ruleset module が付ける）。App に要る権限は Contents: write、install 先はこのリポジトリだけでいい。

credential をクラスタに入れるのは Actions の **Image Updater Credential**（`workflow_dispatch`）。手元に DO の PAT を持たなくてよく、鍵を替えたときもクラスタを作り直したときも同じ workflow を回すだけで戻る。

先に一度だけ App の3つの値を登録する。2つの id は識別子なので variable、**private key は GitHub に置かず Parameter Store に入れる**（→ [GitHub App の秘密鍵（AWS KMS）](#github-app-の秘密鍵aws-kms)）。この App の鍵だけは KMS に入れられない——Image Updater がクラスタの中で自分で JWT に署名するので、鍵そのものがクラスタに要る。

```sh
gh variable set IMAGE_UPDATER_APP_ID --body 4703313
gh variable set IMAGE_UPDATER_APP_INSTALLATION_ID --body <Installation ID>
mise run image-updater:key < <app>.private-key.pem
```

```sh
gh workflow run image-updater-credential.yml
```

`githubAppID` に入れるのは **App ID**（数値）。GitHub は JWT の `iss` に Client ID を使うことを推奨しているが、Image Updater は base 10 で parse するので Client ID を入れると `invalid value in field githubAppID` で落ちる。ruleset の bypass actor に足す `actor_id` も同じ App ID。

Secret ができるまで Image Updater は新しい digest を見つけても書き戻せない。Pod は落ちず、`could not get creds for repo` がログに出続けるだけなので、digest が動かないときはまずここを見る。

### UI

`https://argocd.boykush.com` で開く。Backstage と同じく Access（`terraform/access.tf`）のワンタイム PIN を通った先で、Argo CD 自身のログインに admin で入る。

```sh
mise exec -- kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

port-forward でも入れる。tunnel を疑うときの切り分けに。TLS は Cloudflare で終わらせて argocd-server は平文で待っている（`argocd/kustomization.yaml` の `server.insecure`）ので、`http://localhost:8080` を開く。

```sh
mise exec -- kubectl -n argocd port-forward svc/argocd-server 8080:80
```

### Backstage

[boykush/github-management](https://github.com/boykush/github-management) の `catalog/`（repo をまたいで作用する関係のカタログ）を見る Backstage。公式 image（`ghcr.io/backstage/backstage`）をそのまま使い、この repo が持つのは manifest と、image 既定の設定に重ねる `applications/backstage/app-config.yaml` だけ。

`https://backstage.boykush.com` で開く。tunnel で公開しているが、前段の **Cloudflare Access が owner のメールアドレスしか通さない**（`terraform/access.tf`）。ログインはメールに届くワンタイム PIN で、Access を通った後の Backstage には guest で入る。

Access を外してはいけない。Backstage は guest で誰でもサインインでき permission も allow-all なので、素のまま公開すると、scaffolder の試し実行など guest に許した操作を誰でも動かせてしまう。

例外は path が1つだけある。coding agent が catalog を引く MCP サーバーで、`https://backstage.boykush.com/api/mcp-actions/v1/catalog` を Access の bypass policy で無記名のまま通す。出しているのは read-only の catalog action（`catalog:query-catalog-entities` など）に絞った named server で、絞っていない既定の server（`/api/mcp-actions/v1`。常に全 action を出す）は Access の内側に残る。Access は具体的な path を先に評価するので、この2つは共存する。

```sh
claude mcp add --transport http catalog https://backstage.boykush.com/api/mcp-actions/v1/catalog
```

Access を抜けただけでは足りない。**Backstage は action を無記名では実行しない**——auth policy とは別のチェックで、設定からは外せない（`tools/list` は通るのに `tools/call` が `NotAllowedError` になる）。そこで `backend.auth.externalAccess` に static token を置き、Cloudflare の Transform Rule が同じ path にだけ `Authorization: Bearer` を足す。エージェント側は何も持たない。

**この値は秘密ではない。** Backstage が要求するのは「空白を含まない8文字以上」だけで、一致すれば `subject` がそのまま principal になる——鍵ではなく名札で、通せるのは read-only の catalog action だけ。だから `terraform/access.tf` と `applications/backstage/app-config.yaml` に literal で書いてある（**両方を揃える**。ズレたら 401 で、開きっぱなしにはならない）。秘密にすると、同期と rotate と「Secret が無いと Pod が上がらない」依存を抱える代わりに守れるのは Access の path を誤って広げた場合だけで、割に合わない。

裏を返すと、**境界は Access の path 1本**しかない。`terraform/access.tf` の `domain` と `destinations` を触る変更はそこが全てなので、レビューではそこを見る。

- 通すメールアドレスは public repo に置かず、secret `ACCESS_OWNER_EMAIL` から `TF_VAR_access_owner_email` で渡す。
- ワンタイム PIN は、新しい Zero Trust の組織では既定のログイン方法ではないので、Terraform が identity provider として作る。ダッシュボードで既に足してあると apply が衝突するので、その ID で import する。
- base URL が公開ホスト名なので、port-forward では画面が動かない（API の切り分けにだけ使える）。

catalog は github-management が build する image（`ghcr.io/boykush/github-management-catalog`、public）から、init container が `/catalog` にコピーして読ませる。GitHub の credential は要らない。catalog が更新されると、Image Updater が新しい digest を `applications/backstage/kustomization.yaml` に書き戻し（何を追うかは `applications/backstage/imageupdater.yaml`）、Pod が作り直されて読み直す。

### finlake

[boykush/finlake](https://github.com/boykush/finlake) のお金まわりのデータ。今動いているのは、マネーフォワード ME の CSV を取り込む ingest の CronJob だけ（`applications/finlake/`、namespace `finlake`）。変換の Job と MCP サーバーは後から同じ Application に足す。イメージは `ghcr.io/boykush/finlake` の1つで、サブコマンドで役割を切り替える。新しい digest は Image Updater が `applications/finlake/kustomization.yaml` に書き戻す。

CronJob `ingest` は**毎月 5 日 21:17 JST に前月分**を取り込み、R2 の `raw/moneyforward/month=YYYY-MM/transactions.csv` に置く。5 日にしてあるのは前月の遅れて入る明細（カードの確定、銀行の同期）を待つため。夜に回すのは夜間停止を避けるためで、resume の schedule は実測で 2 時間近く遅れるので、朝だとノードが無いまま Pod が Pending になり、`activeDeadlineSeconds` で落ちる。同じ月を流し直すと上書きするので、手で何度流してもよい。

データの置き場は Cloudflare R2 のバケット `finlake`（`terraform/r2.tf`）。量が月に KB 単位で無料枠に収まり、作るのに要るのが既存の Cloudflare の API トークンだけなので、DO Spaces（月 $5 の定額、CI に全バケットを触れる S3 キーが要る）ではなくこちらにした。

#### Secret

Job の認証情報は2つの Secret で、どちらも kubectl で作り、commit しない。R2 のエンドポイントには Cloudflare の account id が入るので、トークンと一緒に Secret に置いている（public repo に account id を書かない方針のため）。Secret が無い間、Job の Pod は `CreateContainerConfigError` で止まる。

1. **R2 の API トークン**: ダッシュボードの R2 → Manage API tokens で、権限 Object Read & Write、対象をバケット `finlake` だけに絞って作る。出てくる Access Key ID / Secret Access Key と、S3 のエンドポイント（`https://` を除いた `<account_id>.r2.cloudflarestorage.com`）を入れる。

   ```sh
   mise exec -- kubectl -n finlake create secret generic finlake-r2 \
     --from-literal=FINLAKE_S3_ENDPOINT='<account_id>.r2.cloudflarestorage.com' \
     --from-literal=FINLAKE_S3_ACCESS_KEY_ID='<access key id>' \
     --from-literal=FINLAKE_S3_SECRET_ACCESS_KEY='<secret access key>'
   ```

2. **マネーフォワード ME の Cookie**: ログイン済みのブラウザで、`moneyforward.com` へのリクエストの `Cookie` ヘッダを写す。セッションが切れると Job が `moneyforward session expired` で落ちるので、流す前に作り直す。

   ```sh
   mise exec -- kubectl -n finlake create secret generic finlake-moneyforward \
     --from-literal=MONEYFORWARD_COOKIE='<cookie header>' \
     --dry-run=client -o yaml | mise exec -- kubectl apply -f -
   ```

#### 手で流す

前月分なら CronJob からそのまま Job を作る。

```sh
mise exec -- kubectl -n finlake create job --from=cronjob/ingest ingest-manual
mise exec -- kubectl -n finlake logs -f job/ingest-manual
```

前月以外（初回に過去の月をまとめて取り込むときなど）は、引数の `previous` を月に置き換えて作る。Job 名は月ごとに変える。

```sh
month=2026-08
mise exec -- kubectl -n finlake create job --from=cronjob/ingest "ingest-${month}" --dry-run=client -o yaml \
  | sed "s/^\( *\)- previous\$/\1- ${month}/" \
  | mise exec -- kubectl apply -f -
mise exec -- kubectl -n finlake logs -f "job/ingest-${month}"
```

## Claude Code Actions のトークン（AWS）

`boykush` は **User アカウントなので organization secret が無い**。Claude Code Actions を動かす repo ごとに `CLAUDE_CODE_OAUTH_TOKEN` を置くしかなく、実際 wiki は OAuth トークン、scraps は API キーと割れていた。トークンを AWS に1つ置き、**各 repo はその run の OIDC で読む**ことにして、repo 側から秘密を無くす。

| 置き場 | 中身 |
| --- | --- |
| Parameter Store `/claude-code/oauth-token` | トークン本体（SecureString、既定の `aws/ssm` キー） |
| IAM role `github-actions-claude-code` | 読む権限。信頼するのは `claude_code_repositories` に挙げた repo だけ |
| IAM role `github-actions-terraform` | CI がこの設定を apply するための role |
| boykush/workflows の `.github/actions/claude-code-token/` | 各 repo が呼ぶ composite action |

費用は実質 **$0**——standard parameter は保管も API 呼び出しも無料で、IAM と STS にも課金は無い。SecureString の復号で KMS の request が立つが、既定の `aws/ssm` キーに月額は無く、$0.03/10,000 なので月数百回なら $0.01 に届かない。

**Terraform はトークンを持たない**。`aws_ssm_parameter` は refresh のたびに値を読み戻すので、resource にすると HCP の state にトークンが載る。だから parameter だけは CLI で書き、Terraform が持つのは信頼と権限（`terraform/aws.tf`）だけにしてある。

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

**profile 名は `default` で、`AWS_PROFILE` は `[env]` に置かない。** mise の `[env]` は CI にも届く——tool は shim として PATH に載り、shim は実行時に `[env]` を適用するため、`env: false` で `GITHUB_ENV` を塞いでも回り込む。名前付き profile を指していると、CI の terraform が `.aws/config` の無い runner で `failed to get shared config profile` と落ちる。

一時認証情報の方は `~/.aws/login/cache/` に入る（`AWS_LOGIN_CACHE_DIRECTORY` で移せるが、12時間で失効するものなので既定のまま）。

**IAM Identity Center（SSO）は使っていない。** 単一アカウントで有効化すると account instance になり、permission set も AWS アカウントの割り当ても持てない——CLI 用の認証情報はそこからは出てこない。組織インスタンスにするには AWS Organizations が要るが、`aws login` で足りるので構えを取っていない。

**2. 変数を1つ渡す。** root module は1つなので、AWS だけ足すときも宣言済みの変数には値が要る。**実値を入れること**——次の手順では使われないが、同じシェルで後から full apply すると Access のポリシーがその値で書き換わる。

```sh
export TF_VAR_access_owner_email=...
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

`mise exec -- aws login` してから `mise run claude:token` を流すだけ。**`claude setup-token` が出すトークンの有効期間は1年**なので、定期の入れ替えはその周期。漏洩を疑ったときは即座に同じ手順で差し替える。**22 repo に `gh secret set` して回る必要が無い**のがこの構成の実利で、現実的に回せる頻度が上がる。

### repo を足す

1. `terraform/variables.tf` の `claude_code_repositories` に1行足す（これで trust policy が広がる）
2. その repo の workflow に2 step 足す

```yaml
    permissions:
      id-token: write # 以下は既存の permissions に足す

    steps:
      - name: Fetch the Claude Code token
        id: claude-token
        uses: boykush/workflows/.github/actions/claude-code-token@<sha>

      - name: Run Claude Code
        uses: anthropics/claude-code-action@cfc3eb22bfed5c26ef66e3223c982af27e4524de # v1.0.231
        with:
          claude_code_oauth_token: ${{ steps.claude-token.outputs.token }}
```

composite action も他の action と同じく **SHA で固定する**（zizmor が未固定を落とす）。追従は Renovate に任せる。PR の ai-review を入れるだけなら step は書かず、boykush/workflows の README にある呼び出し側を置く。

**`sub` クレームの形式は repo の作成時期で違う**。[2026-07-15 以降に作られた repo](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/) は `repo:<owner>@<owner_id>/<repo>@<repo_id>:...` と ID 入りになり、それ以前の repo は opt-in するまで名前だけ。trust policy は**両方を列挙している**ので足す側は意識しなくていいが、片方しか無いと作成時期次第で `Not authorized to perform sts:AssumeRoleWithWebIdentity` になる——CI から見えるのはこのメッセージだけなので、実際に届いた `sub` は CloudTrail の `AssumeRoleWithWebIdentity` イベントで確かめる。

### 限界

**runner の上にはトークンが載る**。repo secret と比べて消えるのは「GitHub 側に長命な秘密が残ること」「ローテーションが repo の数だけ要ること」で、run 中の漏洩リスクは変わらない——[OIDC でも残る漏洩リスク](https://blog.flatt.tech/entry/2026-github-actions-security-part3)が言う通り。

緩和は2つだけ効かせてある。composite action は `output-env-credentials: false` で **AWS の認証情報を job の環境に置かず**、読み取り step にだけ渡す。role が読めるのは parameter 1本だけで、他の AWS 権限は持たない。**Claude の step が任意コードを実行する以上、そこから先は分離できない**——認証 step と実行 step を別 job にする定石が、この workload では使えない。

構造的に無くすなら [Claude 自身の WIF](https://platform.claude.com/docs/en/manage-claude/workload-identity-federation)（`anthropic_federation_rule_id`）で、トークンそのものが不要になる。ただし organization の service account として **API 従量課金**になり、Max のシートは使えない。

## GitHub App の秘密鍵（AWS KMS）

**GitHub App の private key には期限が無い**。repo secret に置いた鍵は、漏れてから App に登録したままにしている限り、いつまでもインストールトークンを発行できる。鍵を **AWS KMS に取り出せない形で入れ**、JWT の署名だけを KMS に任せることにして、GitHub 側から鍵を消した。workflow が持つのは「署名できること」で、それは IAM で剥がせる。

差し替え先は [`suzuki-shunsuke/create-github-app-token-aws-kms`](https://github.com/suzuki-shunsuke/create-github-app-token-aws-kms)。`actions/create-github-app-token` と入出力が揃っていて、`private-key` が `kms-key-id` に替わる。使う側が直接呼ぶのではなく、[boykush/workflows](https://github.com/boykush/workflows) の `github-app-token` action を通す——alias も role の ARN も App 名から決まるので、そこで組み立てて渡している。

どの App があり、どの repo が署名してよいかは `terraform/variables.tf` の `github_apps` が持つ。KMS の alias（`alias/github-app-<name>`）も署名する role もその名前から決まるので、ここには写さない。`image-updater` だけはその list に無く、鍵の置き場も違う——理由は下記。

App の id（App ID / Client ID）はここに書かない。台帳は github-management の catalog（`resource:<app>-app` の annotation）で、run から引く写しを `github-app-token` が持つ。

**`image-updater` だけ KMS に入らない。** Image Updater はクラスタの中で自分で JWT に署名するので、渡すものが鍵そのものになる——KMS は鍵を返さないので、入れても使えない。この1つは SecureString（既定の `aws/ssm` キー）に置き、**Image Updater Credential** が OIDC で読んでクラスタの Secret にする。GitHub 側から鍵が消える点は同じで、違うのは鍵が AWS から出るかどうかだけ。

費用は **key 1本 $1/月**（本数は `github_apps` の数）。署名は RSA 2048 の request なので $0.03/10,000——Renovate を毎時回しても月 $0.01 に届かない。Parameter Store 側はこれまでどおり $0。

**鍵は Terraform を通らない**。`key_material_base64` を渡すと private key が HCP の state に載るので、Terraform が作るのは **material の入っていない空の key**（origin EXTERNAL、`PendingImport`）と、それで署名できる role だけ。material は CLI で入れる。

**role は App ごとに分ける**。1つの role に全部の key への `kms:Sign` を持たせると、renovate-runner の run が「全 repo を管理する App」として署名できてしまう。trust policy が列挙するのはその App を使う repo だけで、対応は `terraform/variables.tf` の `github_apps` が持つ。

**CI は key を作れるが使えない**。`github-actions-terraform` が持つのは KMS の管理操作だけで、`kms:Sign` も `kms:ImportKeyMaterial` も `kms:PutKeyPolicy` も無い——この repo の run が App として署名することも、key の中身を入れ替えることも、key policy で自分に権限を足すこともできない。

### App を1つ入れる

**1. `terraform/variables.tf` の `github_apps` に足す。** `name` が KMS の alias と role の名前になり、`repositories` がその App として署名できる repo になる。main の run からだけ署名させる App は `main_only = true` にする（理由はそこのコメント）。

**2. merge する。** **apply はローカルでやらない**。CI の role が持つ `iam:*` は ARN の列挙だが、そこに載る役割名は `github_apps` から**文字列で**組んである——resource の ARN を読むと policy が role の後ろに並び、「作る権限を与える更新」が「作る」より後に来てしまう。`depends_on` で policy の更新を先に置いてあるので、key も role も同じ apply の中で作れる。

IAM の反映は結果整合なので、広がった直後の `CreateKey` が稀に `AccessDenied` を返すことがある。その時は workflow を再実行する（apply は冪等）。

**3. 鍵を入れる。** ここだけは手元でやる——PEM が手元にしか無いため。**KMS は1つの key に material を1度しか受け付けない**（同じ material なら再インポートできるが、別の material は入らない）。

```sh
mise run app:key-import renovate ~/Downloads/<app>.private-key.pem
```

KMS は wrap した material しか受け取らず、RSA-OAEP だけでは 2048bit の鍵（PKCS#8 DER で 1217 バイト）が包めないので AES-KWP が要る。macOS の `openssl` は LibreSSL でそれを持たないため、この task だけ node の `crypto` を借りている。**node は task の tool として宣言してある**ので、初回に mise が入れるだけで、`mise install` にも CI にも降りてこない。

`KeyState: Enabled` が返れば入っている。**ここで手元の PEM を消す**——これ以降どこからも読み出せない値で、残しておくと KMS に入れた意味が減る。

**手元に PEM が無ければ App の設定で作り直す。** repo secret に入れた鍵は読み出せないので、既に secret に置いてある App を移すときは必ずこうなる。App は private key を複数持てるので、**新しい鍵を生成 → KMS に入れる → workflow を差し替える → 古い鍵を App から revoke** の順なら、途中で動かない時間ができない。同じことが `image-updater` の鍵（`mise run image-updater:key`）にも当てはまる。

**4. App の id を台帳に足す。** github-management の `catalog/github-apps.yaml` に `<name>-app` の Resource を書き、annotation に App ID か Client ID を入れる。同じ値を boykush/workflows の `github-app-token` の表にも足す——workflow が渡すのは App 名だけなので、名前から id を引けないとトークンは出ない。

**5. 使う側の repo の workflow を差し替える。**

```yaml
    permissions:
      id-token: write # 既存の permissions に足す

    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: boykush/workflows/.github/actions/github-app-token@<SHA>
        with:
          app: renovate
          permission-contents: write
```

`permission-*` は**最低1つ必須**で、ここが公式の action と違う。AWS の認証は action の中で完結し、後続の step には渡らない。alias も role の ARN も region も `app` から決まるので、使う側は ARN を持たない。

**6. その repo の secret を消す。** `gh secret delete RENOVATE_APP_PRIVATE_KEY`。ここで初めて「鍵が GitHub に無い」状態になる。

### 鍵を入れ替える

App 側で private key を作り直したら、**KMS の key も作り直す**。material は入れ替えられないので、key を replace して alias を新しい key に向け、そこへ新しい PEM を入れる。role の policy も新しい ARN に書き換わるので、`-target` はこの3つ。alias を名指ししているのは `github-app-token` なので、使う側の workflow は触らなくていい。

```sh
mise exec -- terraform -chdir=terraform apply \
  -replace='aws_kms_external_key.github_app["renovate"]' \
  -target='aws_kms_external_key.github_app["renovate"]' \
  -target=aws_kms_alias.github_app \
  -target=aws_iam_role_policy.github_app
mise run app:key-import renovate ~/Downloads/<app>.private-key.pem
```

古い key は 30 日の待機を経て消える（その間は `kms:CancelKeyDeletion` で戻せる）。**key を消すことは鍵を失うこと**で、手元の PEM はもう無い——戻す道は App 側で鍵を作り直して入れ直すことだけ。`prevent_destroy` を付けていないのはクラスタと同じ理由で、作り直せるものを消せなくしないため。

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

kubectl をリポジトリ側で固定しているのは、マシン全体の client（1.30）が DOKS 1.36 に対して skew（±1 minor）を超えているため。

## Local development

state は HCP Terraform（`cloud {}` backend）にあるので、`init` 以降は認証が要る。

```sh
mise install                            # toolchain を導入
mise run tf:login                       # HCP backend 認証（一度だけ）
doctl auth init                         # DO の PAT を入力（~/.config/doctl/config.yaml に保存）
export DIGITALOCEAN_ACCESS_TOKEN=...    # provider 用（doctl と同じ変数名）
export TF_VAR_access_owner_email=...    # Access が通すアドレス（public repo に置かないため変数で渡す）

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
| `CLOUDFLARE_API_TOKEN` | `cloudflare` provider（tunnel、DNS、Access） |
| `ACCESS_OWNER_EMAIL` | Access が通すメールアドレス（`TF_VAR_access_owner_email`） |

**Image Updater Credential**（`workflow_dispatch`）は Image Updater の GitHub App credential を Secret `argocd/image-updater-git-creds` として適用する。Secret を書くので push では起動しない。private key は repo secret ではなく Parameter Store から OIDC で読む（`github-actions-image-updater` role）ので、この repo が持つ App の秘密はもう無い。

HCP の workspace `infrastructure-as-code` は Execution Mode = **Local**（実行は CLI / CI 側、HCP は state + lock のみ）。

## 夜間停止（`node-pool-park.yml` / `node-pool-resume.yml`）

worker node を毎晩 0 台に落として朝に戻す。課金対象は node だけなので、止めている間は課金されない。

| workflow | cron（UTC） | JST | 動作 |
| --- | --- | --- | --- |
| **Node Pool Park** | `37 16 * * *` | 01:37 | node pool を 0 に |
| **Node Pool Resume** | `37 21 * * *` | 06:37 | 1 に戻し、配信が戻るまで待つ |
| **Node Pool Status** | dispatch のみ | | node pool / droplet / node を読むだけ |

やることが違う（resume だけが復帰を待つ）ので workflow を分けてある。どちらも `workflow_dispatch` を持つので、手動実行がそのまま動作確認と復旧手段になる。`concurrency` group は共通（`node-pool`）で、park と resume は重ならない。

- **停止中は tunnel の先がすべて落ちる**（`terraform/variables.tf` の `tunnel_routes`。catalog の MCP も含む）。cloudflared ごと消えるので Cloudflare が 530 を返す。
- resume の gate は `cloudflared` と MCP サーバー（`wiki` / `adr` / `backstage`）の rollout **だけ**。ノードの Ready は見ない——削除中のノードも Ready を返すので、park 直後の resume がそれを掴んで素通りする。
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
- `node_count` は Terraform の `ignore_changes` 対象。main への apply がこの workflow と競合しない。
- 止めたくない日は Actions の UI から workflow を disable する。
- schedule は repo が 60 日無活動だと自動停止するが、Image Updater の commit が入るので実質起きない。

## 費用

クラスタで課金されるのは worker node だけで、control plane と VPC は無料。MCP サーバーの公開に Cloudflare Tunnel を使っているのも、Load Balancer（$12/月〜）を増やさないため。AWS 側は GitHub App の鍵を持つ KMS の key が **1本 $1/月**（今は4本で $4/月）で、それ以外——IAM・STS・standard parameter——は保管も呼び出しも無料。finlake の R2 は無料枠（保存 10 GB/月、書き込み 100 万回・読み取り 1000 万回/月、転送は無料）に収まるので $0。

node は秒課金（$0.03571/時）だが **月 672 時間（28 日）で頭打ち**になる。連続稼働なら毎月この上限に当たるので $24/月で一定、裏を返せば月 48 時間までの停止は請求に効かない。

| 稼働 | 課金時間 | ノード代 |
| --- | --- | --- |
| 連続（30 日） | 672（上限） | $24.00 |
| 夜間停止 5.0h/日（30 日） | 570 | $20.35 |
| 同、park が毎晩 3 時間遅れた月 | 660 | $23.57 |

停止が 5 時間しか取れないのは、夜の作業が 01:00 過ぎまで伸びる一方で朝の締切が 10 時だから。そこに最大 3 時間の schedule 遅延が乗るので、**節約は遅延次第で $3.65 から $0.43 まで振れる**。窓を広げるには GitHub の schedule 以外の発火元（Cloudflare Workers の Cron Trigger から `workflow_dispatch` を叩くなど）が要る。

outbound 転送は月 4,000 GiB まで無料で、超過分が $0.01/GiB——従量なのはここだけ。使わない期間は `terraform destroy` で完全に止められる——`destroy_all_associated_resources = true` なので、クラスタが作った LoadBalancer / volume も一緒に消える。**ただし root module は1つなので、素の destroy は KMS の key まで消しにいく**（= App の鍵を失う）。止めたいのはノード代なので、`-target=digitalocean_kubernetes_cluster.this` で絞るか、夜間停止をそのまま使う。
