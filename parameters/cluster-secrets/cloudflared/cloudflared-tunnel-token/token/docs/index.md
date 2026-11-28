# /cluster-secrets/cloudflared/cloudflared-tunnel-token/token

cloudflared が Cloudflare Tunnel に繋ぐための tunnel token。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/cloudflared/externalsecret.yaml) が cluster の Secret `cloudflared/cloudflared-tunnel-token` の key `token` にする（反映は `refreshInterval` ごと）。
tunnel は Terraform が作り、token はその output `tunnel_token`（[`terraform/outputs.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/outputs.tf)）。

## 入れ替える

tunnel を作り直したときだけ変わる。期限は無い。token は Cloudflare の画面ではなく Terraform の output から取る。
`mise run tf:login` と `mise exec -- aws login` の後、infrastructure-as-code の checkout で:

```sh
mise exec -- terraform -chdir=terraform output -raw tunnel_token \
  | mise run cluster:secret cloudflared cloudflared-tunnel-token token
mise exec -- kubectl -n cloudflared rollout restart deployment/cloudflared
```

## 確かめる

- [Zero Trust の Networks → Tunnels](https://one.dash.cloudflare.com/) で tunnel が HEALTHY であること。
- 公開しているホスト名（例 `https://argocd.boykush.com`）が開くこと。

## 古い値

tunnel を作り直すと前の tunnel ごと token は無効になる。Parameter Store は上書きしても前の version を履歴に残す（parameter ごとに 100 件まで）。
