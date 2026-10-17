---
name: add-claude-code-repo
description: boykush の repo が Claude Code Actions のトークンを AWS から OIDC で読めるようにする。「この repo で Claude Code Actions を動かしたい」「claude_code_repositories に足す」「CLAUDE_CODE_OAUTH_TOKEN を repo secret から外す」ときに使う。
---

# Claude Code Actions のトークンを読める repo を足す

## 前提

- トークンの置き場と、それを読む role は `terraform/aws.tf` が持つ。`sub` の形式と `repo:<owner>/*` に広げない理由は AGENTS.md の「AWS の認証情報」節にある。
- `terraform apply` はローカルで実行しない。merge 後の CI が apply して trust policy が広がる。

## 手順

1. `terraform/variables.tf` の `claude_code_repositories` に1行足す（これで trust policy が広がる）
2. その repo の workflow に2 step 足す

```yaml
    permissions:
      id-token: write # 以下は既存の permissions に足す

    steps:
      - name: Fetch the Claude Code token
        id: claude-token
        uses: boykush/workflows/.github/actions/claude-code-token@<sha>

      - name: Run Claude Code
        uses: anthropics/claude-code-action@<sha>
        with:
          claude_code_oauth_token: ${{ steps.claude-token.outputs.token }}
```

composite action も他の action と同じく **SHA で固定する**（zizmor が未固定を落とす）。追従は Renovate に任せる。PR の ai-review を入れるだけなら step は書かず、boykush/workflows の README にある呼び出し側を置く。

## 失敗の見え方

`Not authorized to perform sts:AssumeRoleWithWebIdentity` は、trust policy が届いた `sub` を知らないとき。CI から見えるのはこのメッセージだけなので、実際に届いた `sub` は CloudTrail の `AssumeRoleWithWebIdentity` イベントで確かめる。
