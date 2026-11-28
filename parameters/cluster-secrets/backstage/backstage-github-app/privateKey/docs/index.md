# /cluster-secrets/backstage/backstage-github-app/privateKey

Backstage が各 repo の `catalog-info.yaml` を読む GitHub App
（[repo-reader-app](https://backstage.boykush.com/catalog/default/resource/repo-reader-app)）の private key（PEM）。
[`ExternalSecret`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/backstage/externalsecret.yaml) が cluster の Secret `backstage/backstage-github-app` の key `privateKey` にする（反映は `refreshInterval` ごと）。
App ID と Client ID は識別子なので [`app-config.yaml`](https://github.com/boykush/infrastructure-as-code/blob/main/applications/backstage/app-config.yaml) に直接書いてある。

Backstage は自分で JWT に署名するので、この鍵は KMS に入らない。

## 入れ替える

漏れたかもしれないとき、App を作り直したときに行う。

1. [GitHub の App 一覧](https://github.com/settings/apps) で App を開き、Private keys の Generate a private key で新しい鍵を足す。
2. `mise exec -- aws login` の後、infrastructure-as-code の checkout で書き、Backstage を再起動する
   （Secret を env で読むので、再起動まで古い鍵のまま）:

   ```sh
   mise run cluster:secret backstage backstage-github-app privateKey < <app>.private-key.pem
   mise exec -- kubectl -n backstage rollout restart deployment/backstage
   ```

3. 下の「確かめる」が通ったら、App の画面で古い鍵を Delete する。
4. 手元の PEM を消す。

## 確かめる

Backstage の catalog で、どれかの repo の `catalog-info.yaml` を直した変更が数分で反映されること。
鍵が無いと Backstage は起動しない（`CreateContainerConfigError`）。鍵が古いと起動はするが、Discovery が 401 を出し、
repo の entity が増えも減りもしなくなる。

## 古い値

古い鍵は手順 3 で App から消す。Parameter Store は上書きしても前の version を履歴に残す（parameter ごとに 100 件まで）。
