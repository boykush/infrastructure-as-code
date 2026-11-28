# /cluster-secrets/finlake/finlake-r2-sync/FINLAKE_S3_ACCESS_KEY_ID

finlake が R2 のバケット `finlake` を読み書きする R2 API token の Access Key ID。
`FINLAKE_S3_SECRET_ACCESS_KEY` と対で、2 つは同じ手順で同時に替わる。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/finlake/externalsecret.yaml) が cluster の Secret `finlake/finlake-r2-sync` の key `FINLAKE_S3_ACCESS_KEY_ID` にする（反映は `refreshInterval` ごと）。
CronJob `sync` と Deployment `mcp` が同じ Secret を読む。

## 入れ替える

期限が近いとき、漏れたかもしれないときに行う。

1. [R2 → Manage API tokens](https://dash.cloudflare.com/?to=/:account/r2/api-tokens) で token を作る。Token name は `cloudflare-finlake-r2`（この Resource と
   `cloudflare-finlake-r2-secret-access-key` の name の頭）。権限は Object Read & Write、対象はバケット `finlake` だけに絞る。
   期限を付ける。
2. 出てきた Access Key ID と Secret Access Key を、`mise exec -- aws login` の後、infrastructure-as-code の
   checkout で 1 つずつ貼って Ctrl-D:

   ```sh
   mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_ACCESS_KEY_ID
   mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_SECRET_ACCESS_KEY
   ```

3. 反映（`refreshInterval` ごと）を待ってから、Secret を env で読む `mcp` を再起動する:

   ```sh
   mise exec -- kubectl -n finlake rollout restart deployment/mcp
   ```

## 確かめる

`mcp` が新しい Pod で動き、sync を手で流して（skill `run-finlake-sync`）通ること。

## 古い値

`sync` と `mcp` の両方が新しい値で動いてから、[R2 → Manage API tokens](https://dash.cloudflare.com/?to=/:account/r2/api-tokens) で古い token を消す。新旧が同じ名前で並ぶので、作成日で見分ける。
Parameter Store は上書きしても前の version を履歴に残す（parameter ごとに 100 件まで）。
