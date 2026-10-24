# infrastructure-as-code

boykush の個人アプリケーションを載せる Kubernetes 基盤のリポジトリ。クラスタ（DigitalOcean Kubernetes / DOKS）を Terraform で作り、その上のアプリケーションは Argo CD で GitOps デプロイする。

費用は月 約 4,000 円で、ほとんどが DOKS の node 代（請求はドル建てで $25〜28、1 ドル 150 円で換算、2026-10）。

- 手順は skill（[`.apm/skills/`](.apm/skills/)）、エージェント向けの決まりは [`AGENTS.md`](AGENTS.md)。
- 個々の設定値と、そうした理由は、そのファイルのコメントにある。
