---
name: local-setup
description: このリポジトリを手元で触れるようにする（toolchain、HCP の backend、kubectl）。「terraform init が通らない」「kubectl が繋がらない」「新しいマシンで始める」ときに使う。
---

# 手元の環境を作る

toolchain は `mise.toml` が固定している。個々を固定した理由はそのコメント。

```sh
mise install
mise run tf:login       # HCP の backend。ブラウザで token を発行して貼る（マシンごとに1回）
```

`terraform plan` まで手元で回すなら、provider の認証情報が要る。普段は PR の plan（CI）で足りる。値は CI と同じ Parameter Store の `/ci-secrets` から読む（先に `mise exec -- aws login`）。

```sh
ci_secret() { mise exec -- aws ssm get-parameter --with-decryption --name "/ci-secrets/$1" --query Parameter.Value --output text; }
export DIGITALOCEAN_ACCESS_TOKEN="$(ci_secret digitalocean/infrastructure-as-code)"   # provider と doctl が同じ変数名で読む
export CLOUDFLARE_API_TOKEN="$(ci_secret cloudflare/infrastructure-as-code)"
export TF_VAR_access_owner_email="$(ci_secret access/owner-email)"
export TF_VAR_access_github_client_secret="$(ci_secret access/github-client-secret)"
mise exec -- terraform -chdir=terraform init
mise exec -- terraform -chdir=terraform plan
```

- `terraform fmt` は認証が要らない。
- **`apply` は手元で実行しない**（AGENTS.md の「ワークフロー」）。
- kubeconfig は `mise run k8s:kubeconfig`。context 名は `do-sgp1-boykush-cluster`。
