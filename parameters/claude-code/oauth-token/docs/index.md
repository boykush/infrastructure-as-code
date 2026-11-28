# /claude-code/oauth-token

Claude Code Actions が使う OAuth token（`claude setup-token` で発行、有効期間は1年）。
どの repo の workflow が読めるかは [`terraform/variables.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/variables.tf) の
`claude_code_repositories` が持つ。

## 入れ替える

期限が近いとき、漏れたかもしれないときに行う。

1. 手元で `claude setup-token` を実行し、出てきた token をコピーする。
2. infrastructure-as-code の checkout で `mise exec -- aws login` の後、次を実行して貼り、Ctrl-D。
   端末幅で折り返された改行は task が落とし、`sk-ant-oat` で始まるかを確かめる。

```sh
mise run claude:token
```

読む側の repo は何も触らなくていい。

## 確かめる

値は出さず、version が上がったことだけを見る。

```sh
mise exec -- aws ssm get-parameter --region ap-northeast-1 --name /claude-code/oauth-token \
  --query 'Parameter.{Version:Version,Type:Type}'
```

経路全体が通ったかは、token を読む workflow（ai-review を入れた repo の PR の review）が次に動いたときに分かる。

## 古い値

Parameter Store は上書きしても前の version を履歴に残す（parameter ごとに 100 件まで）。古い token はこの手順では取り消されず、期限まで有効なまま残る。漏れたかもしれないときは、
[claude.ai の設定](https://claude.ai/settings) で Claude Code の接続を確かめる。
