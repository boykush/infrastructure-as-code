# /cluster-secrets/finlake/finlake-r2-sync/FINLAKE_S3_ENDPOINT

finlake が R2 に繋ぐ S3 エンドポイント（`https://` を除いた `<account_id>.r2.cloudflarestorage.com`）。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/finlake/externalsecret.yaml) が cluster の Secret `finlake/finlake-r2-sync` の key `FINLAKE_S3_ENDPOINT` にする（反映は `refreshInterval` ごと）。
秘密ではないが、account id が git のどこにも無い（Terraform が domain から引く）ので、ここに置いている。

## 入れる

Cloudflare の account が変わったときだけ変わる。値は [R2 の Overview](https://dash.cloudflare.com/?to=/:account/r2/overview)
の Account Details にある S3 API の URL から `https://` を除いたもの。`mise exec -- aws login` の後:

```sh
mise run cluster:secret finlake finlake-r2-sync FINLAKE_S3_ENDPOINT
mise exec -- kubectl -n finlake rollout restart deployment/mcp
```

確かめ方は [`FINLAKE_S3_ACCESS_KEY_ID`](https://backstage.boykush.com/docs/default/resource/cloudflare-finlake-r2-access-key-id/) のページと同じ。
