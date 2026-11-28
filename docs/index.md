# 人が行う作業

この repo の作業のほとんどは、エージェントが `.apm/skills/` の skill に沿って進める。ここに置くのは、エージェントには
できず人が手を動かす部分——各サービスのコンソールでの発行や、ブラウザでの承認——の手順だけ。

どの値をいつ入れ替えるか、どこに置くかは `rotate-credential` の skill（`.apm/skills/rotate-credential/SKILL.md`）が持つ。
ここはその中で「人間に頼む」とされている段の、画面の上での手順を書く。

- [HCP Terraform の API token](hcp-terraform-token.md)

Parameter Store の `/secrets` に置いた資格情報の入れ替えは、鍵ごとのページにある。catalog で Kind を
Resource、Type を `ssm-parameter` に絞ると一覧になる（[絞り込み済みの一覧](https://backstage.boykush.com/catalog?filters%5Bkind%5D=resource&filters%5Btype%5D=ssm-parameter)）。
各 Resource の Docs タブが、その鍵の発行先と手順を持つ。
