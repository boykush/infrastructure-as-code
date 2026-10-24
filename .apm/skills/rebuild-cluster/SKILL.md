---
name: rebuild-cluster
description: DOKS クラスタを消した後、または作り直したときに、Argo CD と Secret まで戻す。「クラスタを作り直す」「destroy したのを戻す」「bootstrap する」「クラスタが空になった」ときに使う。
---

# クラスタを作り直す

## 前提

- 戻る順は下の手順の順そのもの：クラスタ → Argo CD → External Secrets Operator の鍵 → 残りの Secret。operator は自分の鍵だけは取れないので、そこだけ workflow で入れる。
- **手元からは apply しない。** クラスタ本体は CI の apply が作る。Argo CD の bootstrap のような一度きりの操作も、一時 workflow で行い、済んだら消す。
- 消すときは `-target=digitalocean_kubernetes_cluster.this` で絞ったはず。素の destroy だった場合は KMS の鍵も消えているので、App ごとに skill `add-github-app` の「鍵を入れ替える」をやり直す。

## 手順

**1. クラスタを作る。** CI の apply が作る。`terraform.yml` に dispatch は無く、push の apply は path で絞られているので、`terraform/` を触る PR が merge されたときに走る。

**2. Argo CD を bootstrap する一時 workflow を書く。** `workflow_dispatch` だけで起動し、kubeconfig は `external-secrets-credential.yml` と同じく `doctl kubernetes cluster kubeconfig save boykush-cluster --expiry-seconds 600` で取る。中身は次の3行。

```sh
kubectl apply -k argocd --server-side
kubectl -n argocd rollout status statefulset/argocd-application-controller
kubectl apply -f applications/root.yaml
```

`permissions:` は `contents: read` だけ書く。PR で merge し、dispatch して通ったら、**同じ workflow を消す PR を出す**。以降は `applications/` を root Application が拾う。

**3. External Secrets Operator の鍵を入れる。** operator が自分で取れない唯一の Secret。

```sh
gh workflow run external-secrets-credential.yml
```

operator が同期を始めれば、残りの Secret は Parameter Store から全部戻る。tunnel を作り直していないなら tunnel token もそのまま使える（作り直したなら skill `rotate-credential`）。

## 確かめる

- Argo CD の画面（`https://argocd.<ドメイン>`）で全 Application が Synced / Healthy になること。
- `CreateContainerConfigError` で止まる Pod が無いこと。あれば、その Secret の parameter が Parameter Store に無い。
- `node-pool-resume.yml` を dispatch して通ること。tunnel から MCP サーバーまでの rollout を待つので、公開経路が戻ったかの確認になる。
