# 費用と停止

## 覚えておくこと

- 費用は月 $25〜28 で、ほとんどが DOKS（DigitalOcean Kubernetes）の node 代。夜間停止で浮くのは月 $0.4〜3.7。
- 止めている間は、公開しているものが全部落ちる。MCP と Backstage も含む。
- 長く止めるときに、素の `terraform destroy` はしない。GitHub App の鍵まで消える。

ここから下は、停止の仕方や費用の構成を変えるときに読む。

## 何に払っているか

| 内訳 | 月額 | 額を決めているもの |
| --- | --- | --- |
| DOKS の worker node | $20.35〜23.57 | `terraform/variables.tf` の `node_size`（$24/月）と夜間停止 |
| KMS の key | $4 | 1本 $1。本数は `terraform/variables.tf` の `github_apps` |
| Jaeger の volume | $0.10 | $0.10/GiB。サイズは `applications/jaeger/pvc.yaml` |
| 合計 | 約 $25〜28 | |

ほかは $0。DOKS の control plane・VPC・IAM・Parameter Store は無料で、R2 と outbound 転送は無料枠に収まる。公開は Cloudflare Tunnel なので、Load Balancer も無い。

node は秒課金だが、月 672 時間（28 日）で頭打ちになる。だから月 48 時間までの停止は請求に効かない。volume は node を止めても課金が続く。

## 夜間停止

worker node を毎晩 0 台に落とし、朝に戻す。workflow は `node-pool-park.yml` と `node-pool-resume.yml` で、時刻とその理由は各 `cron` の隣のコメントにある。

| 稼働（30 日） | 課金時間 | node 代 |
| --- | --- | --- |
| 連続 | 672（上限） | $24.00 |
| 毎晩 5 時間止める | 570 | $20.35 |
| 同、park が毎晩 3 時間遅れる | 660 | $23.57 |

浮く額が $0.43〜$3.65 の幅を持つのは、GitHub の schedule の遅延しだいだから。表は今の cron の 5 時間で計算している。

止めている間は cloudflared ごと消えるので、tunnel の先は Cloudflare が 530 を返す。Jaeger のトレースは volume にあるので消えない。

### 判断に使う実測（2026-09）

| 計測 | 値 |
| --- | --- |
| park 投入 → endpoint 停止 | 約 25 秒 |
| resume 投入 → 配信復帰（ノード破棄済みから） | 11 分 17 秒 |
| 同、2026-09-14 の定期実行 | 3 分 41 秒 |
| schedule の遅延の最大（2026-09-13、Actions にインシデント無し） | park 3 時間 02 分、resume 1 時間 48 分 |

### 気を付けること

- park が 5 時間以上遅れると、resume を追い越して日中ずっと止まる。2つは同じ `concurrency` group で直列になるからで、実測の最大に対する余裕は 2 時間弱。
- 停止の窓を広げるには、GitHub の schedule 以外の発火元が要る。たとえば Cloudflare Workers の Cron Trigger から `workflow_dispatch` を叩く。
- 止めたくない日は、Actions の画面で `node-pool-park.yml` を disable する。
- 課金が止まったかは、ノード名で確かめる。`count 0` に着いた後もしばらく node は列挙される。戻ったときに別名のノードなら、作り直された、つまり課金が切れていた。
- schedule は repo が 60 日無活動だと止まるが、Image Updater の commit が入るので実質起きない。

## 長く使わないとき

`terraform destroy` で全部止まる。クラスタが作った LoadBalancer と volume も一緒に消える（`destroy_all_associated_resources`）。

ただし素の destroy は KMS の key も消す。root module が1つだからで、消えた key は GitHub App の鍵ごと失われる（猶予は [資格情報](credentials.md) の信頼の鎖）。止めたいのは node 代なので、`-target=digitalocean_kubernetes_cluster.this` で絞るか、夜間停止のまま置いておく。戻すときは skill `rebuild-cluster`。
