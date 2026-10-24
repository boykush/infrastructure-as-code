# infrastructure-as-code

boykush の個人アプリケーションを載せる Kubernetes 基盤。DOKS クラスタを Terraform で作り、その上のアプリケーションを Argo CD で GitOps デプロイする。

ここに書くのは、人間が判断するときに要ることだけ。それ以外は持ち主が別にある。

| 知りたいこと | 見る場所 |
| --- | --- |
| repo をまたぐ依存、公開 URL、workload の状態 | Backstage の catalog（この component のページ） |
| 個々の設定値と、そうした理由 | そのファイルのコメント |
| 手順（一度きりのものも含む） | skill（`.apm/skills/`）。エージェントに頼めば、人間の手が要るところだけ頼まれる |
| エージェントが守る禁止と、踏んだ失敗 | `AGENTS.md` |

- [資格情報](credentials.md) — 人間が発行し直すものと、信頼の鎖
- [費用](cost.md) — 月にいくらかかるか
