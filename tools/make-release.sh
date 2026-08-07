#!/usr/bin/env bash
# tools/make-release.sh <tag> — builda o tarball de release (git archive do HEAD) + manifesto
# self-update.json (formato que lib/core/self_update.sh espera) e publica via `gh release
# create`. Extraído de .github/workflows/release.yml pra ser reaproveitado também por
# auto-release.yml (bump automático) — mesma lógica, sem duplicar entre os dois workflows.
#
# Espera rodar dentro de um checkout do repo, com GH_TOKEN e GITHUB_REPOSITORY no ambiente
# (já vêm de graça em qualquer step de Action com `env: GH_TOKEN: ${{ github.token }}`).
set -Eeuo pipefail

tag=${1:?uso: tools/make-release.sh <tag, ex: v0.2.6>}
version=${tag#v}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY não definido — rode isto dentro de uma Action}"

name="pvxcli-${version}"
mkdir -p dist-release
git archive --format=tar --prefix="${name}/" HEAD | gzip >"dist-release/${name}.tar.gz"
sha=$(sha256sum "dist-release/${name}.tar.gz" | awk '{print $1}')

cat >dist-release/self-update.json <<EOF
{
  "version": "${version}",
  "changelog": "notas completas: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${tag}",
  "tarball": {
    "url": "https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}/${name}.tar.gz",
    "sha256": "${sha}"
  }
}
EOF

gh release create "$tag" \
  "dist-release/${name}.tar.gz" \
  dist-release/self-update.json \
  --title "pvx-core ${version}" \
  --generate-notes
