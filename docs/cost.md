# 費用と停止

## 何に払っているか

課金されるのは worker node と Jaeger の volume だけで、control plane と VPC は無料。

- **node**：秒課金（$0.03571/時）だが、**月 672 時間（28 日）で頭打ち**になる。連続稼働なら毎月 $24 で一定。裏を返せば、月 48 時間までの停止は請求に効かない。
- **Jaeger の volume**：$0.10/GiB・月（サイズは `applications/jaeger/pvc.yaml`）。node を止めていても課金が続く。
- **AWS**：GitHub App の鍵を持つ KMS の key が1本 $1/月（本数は `terraform/variables.tf` の `github_apps` の数）。IAM・STS・Parameter Store の standard parameter は、保管も呼び出しも無料。
- **finlake の R2**：無料枠（保存 10 GB/月、書き込み 100 万回・読み取り 1000 万回/月、転送は無料）に収まるので $0。
- **outbound 転送**：月 4,000 GiB まで無料で、超えた分が $0.01/GiB。従量なのはここだけ。

公開に Cloudflare Tunnel を使っているので、Load Balancer（$12/月〜）は無い。

## 夜間停止

worker node を毎晩 0 台に落とし、朝に戻す（`node-pool-park.yml` / `node-pool-resume.yml`）。時刻とその理由は各 workflow の `cron` の隣のコメントにある。

| 稼働 | 課金時間 | ノード代 |
| --- | --- | --- |
| 連続（30 日） | 672（上限） | $24.00 |
| 夜間停止 5.0h/日（30 日） | 570 | $20.35 |
| 同、park が毎晩 3 時間遅れた月 | 660 | $23.57 |

節約は **$0.43〜$3.65/月**で、どちらに寄るかは GitHub の schedule の遅延で決まる。停止が 5 時間しか取れないのは、夜の作業が 01:00 過ぎまで伸びる一方で、朝の締切が 10 時だから。

止めている間は、tunnel の先がすべて落ちる。cloudflared ごと消えるので Cloudflare が 530 を返す。catalog・Jaeger の MCP と Backstage も含む。Jaeger のトレースは volume にあるので消えない。

判断に効く実測（2026-09）：

| 計測 | 値 |
| --- | --- |
| park 投入 → endpoint 停止 | 約 25 秒 |
| resume 投入 → 配信復帰（ノード破棄済みの状態から） | 11 分 17 秒 |
| 同、2026-09-14 の定期実行 | 3 分 41 秒 |
| schedule の遅延の最大（2026-09-13、Actions にインシデント無し） | park 3 時間 02 分、resume 1 時間 48 分 |

- **park が 5 時間以上遅れると、resume を追い越す。** 2つの workflow は同じ `concurrency` group で直列になるので、park が後に回り、日中ずっと止まったままになる。実測の最大に対して余裕は 2 時間弱。
- **窓を広げるには、GitHub の schedule 以外の発火元が要る**（Cloudflare Workers の Cron Trigger から `workflow_dispatch` を叩く、など）。
- **止めたくない日**は、Actions の画面で `node-pool-park.yml` を disable する。
- schedule は repo が 60 日無活動だと止まるが、Image Updater の commit が入るので実質起きない。
- **課金が止まったかは、ノード名で判断する。** `count 0` は desired state で、到達後もしばらく node が列挙される。park を挟むと別名のノードとして戻るので、droplet が作り直された＝課金が切れていた、と分かる。

## 長く使わないとき

`terraform destroy` で全部止められる。クラスタが作った LoadBalancer と volume も一緒に消える（`destroy_all_associated_resources`）。

**ただし素の destroy は KMS の key まで消し、GitHub App の鍵を失う**（root module が1つなので）。止めたいのはノード代なので、`-target=digitalocean_kubernetes_cluster.this` で絞るか、夜間停止のまま置いておく。戻すときは skill `rebuild-cluster`。
