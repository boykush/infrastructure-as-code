# jaeger-remote-mcp

クラスタの workload が出した trace を引くための remote MCP サーバーへの参照を1つ持つだけの plugin。[Agent Plugins](https://agent-plugins.org/specification) の形で書く。名前の `remote` は他の plugin に合わせたもので、port-forward で手元から引く経路はこの repo の README が持つ。

サーバー名は `jaeger`。tool は `mcp__jaeger__*` として見える。読み取りだけ。

## 配る中身

`mcp.json` の、`https://jaeger-mcp.boykush.com/mcp` への参照だけ。実体はこの repo にある。

- **動く場所** は `applications/jaeger/`。MCP は Jaeger 自身が UI と同じポートに出す（`config.yaml` の `ai.mcp`）
- **外向きの hostname と path** は `applications/agentgateway/config.yaml`。UI の hostname（`jaeger.boykush.com`）からは MCP に入れない。URL を変えるなら `mcp.json` も同じ PR で直す
- **認証** は `terraform/access.tf`。Jaeger にログインは無く、前段の Cloudflare Access が token を出し、agentgateway がそれを確かめる

## 使う

Agent Plugin として、この repo のこのディレクトリを `jaeger-remote-mcp--v<version>` の tag で引く。版は `plugin.json` の `version` が持ち、main に入ると [boykush/workflows](https://github.com/boykush/workflows) の agent-plugins が tag を打つ。

隣の `apm.yml` は、apm がこの plugin を Claude と Codex へ展開するための中継ぎで、同じ workflow が `plugin.json` と `mcp.json` から書く。手では直さない。

## 引っかかり所

- **他の plugin と違って認証がある**。初回だけクライアントの OAuth（Claude なら `/mcp`）で GitHub ログインを通す。通るのは Access の owner policy に載っている本人だけなので、CI のような無人のセッションでは使えない
- クラスタは毎晩 01:37〜06:37 JST に落ちる。その間は Cloudflare が 530 を返す。trace 自体は volume に残るので、朝に戻れば引ける
