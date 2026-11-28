# /cluster-secrets/argocd/image-updater-git-creds/githubAppInstallationID

Argo CD Image Updater の GitHub App（[image-updater-app](https://backstage.boykush.com/catalog/default/resource/image-updater-app)）の Installation ID。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/external-secrets/image-updater-git-creds.yaml) が cluster の Secret `argocd/image-updater-git-creds` の key `githubAppInstallationID` にする（反映は `refreshInterval` ごと）。
識別子なので秘密ではないが、鍵と同じ Secret に入るので同じ置き場にある。

install 先はこの repo だけなので、値は 1 つ。[GitHub の Installations](https://github.com/settings/installations) でこの App の Configure を開いたときの URL の末尾の数値。

## 入れる

App を作り直したときだけ変わる。`mise exec -- aws login` の後:

```sh
echo <Installation ID> | mise run cluster:secret argocd image-updater-git-creds githubAppInstallationID
```

確かめ方と古い鍵の扱いは [githubAppPrivateKey](https://backstage.boykush.com/docs/default/resource/github-image-updater-private-key/) のページにある。
