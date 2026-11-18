# jaeger-remote-mcp

クラスタの workload が出した trace を引くための remote MCP サーバーへの参照を1つ持つだけの plugin。[Agent Plugins](https://agent-plugins.org/specification) の形で書く。名前の `remote` は他の plugin に合わせたもので、port-forward で手元から引く経路はこの repo の README が持つ。

サーバー名は `jaeger`。tool は `mcp__jaeger__*` として見える。読み取りだけ。

## 配る中身

`mcp.json` の、`https://jaeger-mcp.boykush.com/mcp` への参照だけ。実体はこの repo にある。

- **動く場所** は `applications/jaeger/`。MCP は Jaeger 自身が UI と同じポートに出す（`config.yaml` の `ai.mcp`）
- **外向きの hostname と path** は `applications/agentgateway/config.yaml`。UI の hostname（`jaeger.boykush.com`）からは MCP に入れない。URL を変えるなら `mcp.json` も同じ PR で直す
- **認証** は `terraform/access.tf`。Jaeger にログインは無く、前段の Cloudflare Access が token を出し、agentgateway がそれを確かめる

## 使う

apm で受け取るなら、[ai-plugins](https://github.com/boykush/ai-plugins) がこの plugin から作る package に依存する。apm は Agent Plugins の形を Claude と Codex へは展開しないので、その変換を ai-plugins が持つ。

```yaml
dependencies:
  apm:
    - boykush/ai-plugins/plugins/jaeger-remote-mcp
```

```bash
apm install
```

Claude は `.mcp.json`、Codex は `.codex/config.toml` に入る。どちらも project scope なので、リポジトリに commit すればそのリポジトリで開いた全セッションに効く。

## 引っかかり所

- **他の plugin と違って認証がある**。初回だけクライアントの OAuth（Claude なら `/mcp`）で GitHub ログインを通す。通るのは Access の owner policy に載っている本人だけなので、CI のような無人のセッションでは使えない
- クラスタは毎晩 01:37〜06:37 JST に落ちる。その間は Cloudflare が 530 を返す。trace 自体は volume に残るので、朝に戻れば引ける
