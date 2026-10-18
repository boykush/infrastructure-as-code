---
name: run-finlake-sync
description: finlake の sync を手で流し、R2 に置いた CSV をすぐ明細に反映する。「CSV を置いたのに反映されない」「月初以外に置いた」「sync が失敗した」ときに使う。
---

# finlake の sync を手で流す

オーナーがマネーフォワード ME から落とした CSV を R2 の raw 層に置くと、CronJob `sync`（`applications/finlake/sync-cronjob.yaml`）が product の明細に変換する。定期で走るのは月初の間だけ（schedule とその理由は manifest）。それ以外の日に置いたとき、置いてすぐ反映したいときは手で流す。変換が要る月が無ければ何もしないので、何度流してもよい。

```sh
mise exec -- kubectl -n finlake create job --from=cronjob/sync "sync-manual-$(date +%s)"
mise exec -- kubectl -n finlake logs -f job/<上で出た名前>
```

置き方の決まり（フォルダ名、1か月に1ファイル）は finlake の README の「データレイク」が持つ。

## 失敗したとき

置き間違い——月のフォルダに CSV が2つ、明細がフォルダの月と違う、フォルダ名が `month=YYYY-MM` でない——があると、その月を変換せずに Job が失敗する。ログに月と理由が出るので、R2 の側を直してもらって流し直す。

Pod が `CreateContainerConfigError` で止まるなら R2 の Secret が無い（skill `rotate-credential`）。
