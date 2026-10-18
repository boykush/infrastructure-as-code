---
name: add-github-app
description: GitHub App の private key を AWS KMS に入れ、指定した repo の workflow がその App として署名できるようにする。鍵の入れ替えもこれで行う。「App を KMS に入れる」「github_apps に足す」「App の鍵を入れ替える」「repo secret の App 鍵を消す」ときに使う。
---

# GitHub App の鍵を KMS に入れる

## 前提

- なぜ KMS に入れるかは `terraform/aws.tf` のコメント、どの App があるかは `terraform/variables.tf` の `github_apps` にある。費用は key 1本 $1/月（`docs/cost.md`）。鍵を Terraform に通さない・role を App ごとに分ける・CI に足さない権限は AGENTS.md の「AWS の認証情報」節にある。
- `image-updater` の App は対象外（鍵がクラスタに要るので KMS に入れられない）。`mise run cluster:secret` で Parameter Store に入れる。

## App を1つ入れる

**1. `terraform/variables.tf` の `github_apps` に足す。** `name` が KMS の alias と role の名前になり、`repositories` がその App として署名できる repo になる。main の run からだけ署名させる App は `main_only = true` にする（理由はそこのコメント）。

**2. merge する。** apply はローカルでやらない。key も role も merge 後の CI の同じ apply の中で作れる（AGENTS.md の「CI の policy は、これから作る role を文字列で名指しする」）。

IAM の反映は結果整合なので、広がった直後の `CreateKey` が稀に `AccessDenied` を返すことがある。その時は workflow を再実行する（apply は冪等）。

**3. 鍵を入れる。** ここだけは手元でやる——PEM が手元にしか無いため。**KMS は1つの key に material を1度しか受け付けない**（同じ material なら再インポートできるが、別の material は入らない）。

```sh
mise run app:key-import <name> ~/Downloads/<app>.private-key.pem
```

`KeyState: Enabled` が返れば入っている。**ここで手元の PEM を消す**——これ以降どこからも読み出せない値で、残しておくと KMS に入れた意味が減る。

**手元に PEM が無ければ App の設定で作り直す。** repo secret に入れた鍵は読み出せないので、既に secret に置いてある App を移すときは必ずこうなる。App は private key を複数持てるので、**新しい鍵を生成 → KMS に入れる → workflow を差し替える → 古い鍵を App から revoke** の順なら、途中で動かない時間ができない。同じことが `image-updater` の鍵（`mise run cluster:secret`）にも当てはまる。

**4. App の id を台帳に足す。** github-management の `catalog/github-apps.yaml` に `<name>-app` の Resource を書き、annotation に App ID か Client ID を入れる。同じ値を boykush/workflows の `github-app-token` の表にも足す——workflow が渡すのは App 名だけなので、名前から id を引けないとトークンは出ない。

**5. 使う側の repo の workflow を差し替える。**

```yaml
    permissions:
      id-token: write # 既存の permissions に足す

    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: boykush/workflows/.github/actions/github-app-token@<SHA>
        with:
          app: <name>
          permission-contents: write
```

`permission-*` は**最低1つ必須**で、ここが公式の action と違う。AWS の認証は action の中で完結し、後続の step には渡らない。alias も role の ARN も region も `app` から決まるので、使う側は ARN を持たない。

**6. その repo の secret を消す。** `gh secret delete <APP>_PRIVATE_KEY`。ここで初めて「鍵が GitHub に無い」状態になる。

## 鍵を入れ替える

App 側で private key を作り直したら、**KMS の key も作り直す**。material は入れ替えられないので、key を replace して alias を新しい key に向け、そこへ新しい PEM を入れる。role の policy も新しい ARN に書き換わる。alias を名指ししているのは `github-app-token` なので、使う側の workflow は触らなくていい。

**replace は一時 workflow で行う**（手元から apply しない）。`workflow_dispatch` だけで起動し、`terraform.yml` と同じ認証（OIDC の role と secret）と `concurrency` group を使って、次を流す。通ったら workflow を消す PR を出す。

```sh
terraform -chdir=terraform apply -auto-approve \
  -replace='aws_kms_external_key.github_app["<name>"]' \
  -target='aws_kms_external_key.github_app["<name>"]' \
  -target=aws_kms_alias.github_app \
  -target=aws_iam_role_policy.github_app
```

PEM を入れるのは手元（PEM が手元にしか無いため）。

```sh
mise run app:key-import <name> ~/Downloads/<app>.private-key.pem
```

古い key は 30 日の待機を経て消える（その間は `kms:CancelKeyDeletion` で戻せる）。**key を消すことは鍵を失うこと**で、手元の PEM はもう無い——戻す道は App 側で鍵を作り直して入れ直すことだけ。`prevent_destroy` を付けていないのはクラスタと同じ理由で、作り直せるものを消せなくしないため。

## 失敗の見え方

| 症状 | 原因 |
| --- | --- |
| action が `KMSInvalidStateException` | key が `PendingImport` のまま（material を入れていない） |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | その repo が `github_apps` の `repositories` に無い。`main_only` の App なら、main 以外の run から来た |
| action が入力エラーで落ちる | `permission-*` が1つも無い |

実際に届いた `sub` も、どの run が署名したかも CloudTrail で見る。`kms:Sign` のセッション名が `gha-<run id>-<run attempt>` なので run まで辿れる。GitHub の監査ログはトークンの行いを App にしか紐付けない。
