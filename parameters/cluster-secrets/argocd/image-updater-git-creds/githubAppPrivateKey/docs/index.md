# /cluster-secrets/argocd/image-updater-git-creds/githubAppPrivateKey

Argo CD Image Updater が main へ digest を書き戻すときに使う GitHub App
（[image-updater-app](https://backstage.boykush.com/catalog/default/resource/image-updater-app)）の private key（PEM）。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/external-secrets/image-updater-git-creds.yaml) が cluster の Secret `argocd/image-updater-git-creds` の key `githubAppPrivateKey` にする（反映は `refreshInterval` ごと）。
App ID と Installation ID も同じ Secret に入る。

この鍵は KMS に入らない——Image Updater が cluster の中で自分で JWT に署名するので、鍵そのものが要る。
**PEM は GitHub にも置かない。**

## 入れ替える

漏れたかもしれないとき、App を作り直したときに行う。止まる時間を作らないため、次の順で進める。

1. [GitHub の App 一覧](https://github.com/settings/apps) で App を開き、Private keys の Generate a private key で新しい鍵を足す。
2. `mise exec -- aws login` の後、infrastructure-as-code の checkout で書く:

   ```sh
   mise run cluster:secret argocd image-updater-git-creds githubAppPrivateKey < <app>.private-key.pem
   ```

3. 下の「確かめる」が通ったら、App の画面で古い鍵を Delete する。
4. 手元の PEM を消す。

## 確かめる

image を更新した後、Image Updater が main に commit（`argocd-image-updater` 名義）を積むこと。
Secret が無い・古いと、Pod は落ちないまま `could not get creds for repo` をログに出し続ける。

```sh
mise exec -- kubectl -n argocd logs deployment/argocd-image-updater-controller --since=1h | grep -i creds
```

## 古い値

古い鍵は手順 3 で App から消す。Parameter Store は上書きしても前の version を履歴に残す（parameter ごとに 100 件まで）。
