---
name: cluster-debug
description: tunnel や Access を迂回して、クラスタの中のサービスに port-forward で直接届く。「画面が開かない」「MCP に繋がらない」「tunnel が悪いのかサービスが悪いのか切り分けたい」ときに使う。
---

# tunnel を迂回して切り分ける

公開しているものは全部、Cloudflare（Access）→ tunnel → （MCP なら agentgateway）→ Service の順に届く。port-forward は前段を全部飛ばして Service に直接届くので、繋がればサービスは生きていて、前段が怪しい。

kubeconfig が無ければ skill `local-setup`。

```sh
mise exec -- kubectl -n <namespace> port-forward svc/<service> <local>:<port>
```

port は各 app の `service.yaml`。開くときに気をつけるもの：

- **Argo CD**（`argocd` / `argocd-server`、80）：TLS は Cloudflare で終わらせ、argocd-server は平文で待っている（`argocd/kustomization.yaml` の `server.insecure`）。`http://localhost:<local>` で開く。
- **Jaeger**（`jaeger` / `jaeger`、16686）：UI と同じポートの `/api/ai/mcp/` が MCP。
- **Backstage**：base URL が公開ホスト名なので、port-forward では画面が動かない。API の切り分けにだけ使える。
- **MCP サーバー**（`remote-mcp-server` の各 Service、finlake の `mcp`）：agentgateway も飛ばすので、token の検証も通らない。サーバー自身の生死だけが分かる。scraps は Host を検証するが、loopback は許可リストに残っているので通る。

## 前段が怪しいとき

- **530**：cloudflared が居ない。夜間停止中なら正常（`node-pool-park.yml`）。
- **`CreateContainerConfigError`**：Secret が無い。skill `rotate-credential`。
- **非公開の MCP が 401**：agentgateway が token を落としている。人が使うエージェントなら Access の再認証（クライアントの `/mcp`）、workflow なら route の `authorization` に repo が載っているか（`applications/agentgateway/config.yaml`）。
- **scraps が 403 `Forbidden: Host header is not allowed`**：Deployment の `--allowed-host` に公開ホスト名かクラスタ内の Service 名が無い。
