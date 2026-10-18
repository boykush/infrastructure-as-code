# infrastructure-as-code

boykush の個人アプリケーションを載せる Kubernetes 基盤のリポジトリ。クラスタ（DigitalOcean Kubernetes / DOKS）を Terraform で作り、その上のアプリケーションは Argo CD で GitOps デプロイする。

- 人間向けの文書は [`docs/`](docs/index.md)。Backstage の TechDocs でも同じものが読める。
- 手順は skill（[`.apm/skills/`](.apm/skills/)）、エージェント向けの決まりは [`AGENTS.md`](AGENTS.md)。
