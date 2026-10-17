---
name: add-mcp-server
description: remote MCP サーバーを1つ増やし、tunnel 経由で `<name>-mcp.<ドメイン>` に公開する PR までを行う。「MCP サーバーを増やしたい」「新しい MCP を公開する」「remote-mcp-server に足す」ときに使う。
---

# remote MCP サーバーを増やす

## 前提

- 公開ホスト名・tunnel の先・route の分け方・非公開にするときの決まりは AGENTS.md の「MCP サーバー」節と「Cloudflare Tunnel」節にある。ここでは繰り返さない。
- イメージのビルドと GHCR への push はアプリ側の repo の CI が行う。この repo には manifest だけを足す。
- `terraform apply` はローカルで実行しない。merge 後の CI が apply する。

## 手順

1. `applications/remote-mcp-server/<name>/` に Deployment / Service / kustomization を置く（`wiki/` と `adr/` が参照実装。Host を検証するサーバーなら `wiki/deployment.yaml` の `--allowed-host` に倣う）
2. `applications/remote-mcp-server/kustomization.yaml` の `resources` と `images` に1行ずつ足す
3. `applications/remote-mcp-server/imageupdater.yaml` の `images` に `alias` / `imageName` / `updateStrategy` を1つ足す
4. `applications/agentgateway/config.yaml` に、公開ホスト名からそのサーバーへの route を1つ足す
5. `terraform/variables.tf` の `tunnel_routes` に `subdomain` を1つ足す（`service` は agentgateway）
6. 非公開にするなら、route に `jwtAuth` を付け、`terraform/access.tf` の Access application `mcp` の `destinations` と `terraform/cloudflare.tf` の `depends_on` に載せる
7. [boykush/github-management](https://github.com/boykush/github-management) の catalog に API を足し、出す repo の component から `providesApis` を張る（書き方は `catalog/apis.yaml` の先頭）。repo をまたぐので別の PR になる

## 確かめる

- PR の `Terraform` check の plan に、DNS record と tunnel の route が1つずつ増えていること
- merge 後、`https://<name>-mcp.<ドメイン>/mcp` に MCP クライアントで繋がること。tunnel を疑うときは port-forward で切り分ける
