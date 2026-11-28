# /external-secrets/access-key-id

External Secrets Operator が Parameter Store を読むための IAM access key の ID。
`/external-secrets/secret-access-key` と対で、2 つは同じ手順で同時に替わる。AWS に残る唯一の長命な鍵。
IAM user と権限は [`terraform/aws.tf`](https://github.com/boykush/infrastructure-as-code/blob/main/terraform/aws.tf) が持つ。

## 入れ替える

漏れたかもしれないとき、AWS の account を作り直したとき、cluster を作り直したときに行う。
`mise exec -- aws login` の後、infrastructure-as-code の checkout で:

```sh
mise run external-secrets:key
gh workflow run external-secrets-credential.yml
```

`external-secrets:key` は IAM user `external-secrets` の古い鍵を消してから新しい鍵を作り、2 つの parameter に書く。
鍵は端末を通らない。cluster を作り直しただけなら（鍵はそのまま）2 行目だけでいい。

workflow が届けるまで operator は同期できないが、cluster にある Secret は残るので、止まるのは更新だけ。

## 確かめる

- [IAM user `external-secrets` の Security credentials](https://us-east-1.console.aws.amazon.com/iam/home#/users/details/external-secrets?section=security_credentials)
  に access key が 1 本だけあること。
- workflow [External Secrets Credential](https://github.com/boykush/infrastructure-as-code/actions/workflows/external-secrets-credential.yml) の run が通り、
  `mise exec -- kubectl get externalsecret -A` がどれも `SecretSynced` であること。

## 古い値

古い鍵は task が IAM で消すので、別の作業は要らない。Parameter Store は上書きしても前の version を履歴に残す（parameter ごとに 100 件まで）。
