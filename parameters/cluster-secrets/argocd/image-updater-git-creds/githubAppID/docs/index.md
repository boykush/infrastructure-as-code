# /cluster-secrets/argocd/image-updater-git-creds/githubAppID

Argo CD Image Updater の GitHub App（[image-updater-app](https://backstage.boykush.com/catalog/default/resource/image-updater-app)）の App ID。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/external-secrets/image-updater-git-creds.yaml) が cluster の Secret `argocd/image-updater-git-creds` の key `githubAppID` にする（反映は `refreshInterval` ごと）。
識別子なので秘密ではないが、鍵と同じ Secret に入るので同じ置き場にある。

**App ID（数値）** を入れる。Image Updater は base 10 で parse するので、Client ID（`Iv` で始まる）を入れると `invalid value in field githubAppID` で落ちる。値は App の画面の About にあり、[image-updater-app](https://backstage.boykush.com/catalog/default/resource/image-updater-app) の annotation `boykush.github.io/github-app-id` にも載っている。

## 入れる

App を作り直したときだけ変わる。`mise exec -- aws login` の後:

```sh
echo <App ID> | mise run cluster:secret argocd image-updater-git-creds githubAppID
```

確かめ方と古い鍵の扱いは [githubAppPrivateKey](https://backstage.boykush.com/docs/default/resource/argocd-image-updater-git-creds-githubAppPrivateKey/) のページにある。
