#!/usr/bin/env bash
# scripts/build_and_publish.sh
set -uo pipefail

: "${FEISHU_APP_ID:?missing FEISHU_APP_ID}"
: "${FEISHU_APP_SECRET:?missing FEISHU_APP_SECRET}"
: "${FEISHU_FOLDER_TOKEN:?missing FEISHU_FOLDER_TOKEN}"
: "${AUR_PACKAGE_NAME:?missing AUR_PACKAGE_NAME}"
: "${AUR_GIT_NAME:?missing AUR_GIT_NAME}"
: "${AUR_GIT_EMAIL:?missing AUR_GIT_EMAIL}"
: "${AUR_SSH_PRIVATE_KEY:?missing AUR_SSH_PRIVATE_KEY}"
: "${GH_TOKEN:?missing GH_TOKEN}"
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"

ROOT="${GITHUB_WORKSPACE:-$PWD}"
WORKDIR="$ROOT/.ci-work"
AURGEN="$WORKDIR/aur-gen"
AURREPO="$WORKDIR/aur-repo"

rm -rf "$WORKDIR"
mkdir -p "$AURGEN"

get_feishu_token() {
  curl -fsS -X POST \
    "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg id "${FEISHU_APP_ID}" --arg secret "${FEISHU_APP_SECRET}" \
      '{app_id:$id, app_secret:$secret}')" \
  | jq -r '.tenant_access_token'
}

choose_latest_deb_zip() {
  jq -r '
    .data.files
    | map(select(.name | test("-deb\\.zip$")))
    | sort_by(.modified_time | tonumber)
    | last
    | [.name, .token]
    | @tsv
  '
}

extract_version_from_name() {
  local name="$1"
  if [[ "$name" =~ .+-([0-9][A-Za-z0-9._-]*)-deb\.zip$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "Cannot parse version from: $name" >&2
    exit 1
  fi
}

echo "[1/5] Query Feishu folder and check version"
FEISHU_TOKEN="$(get_feishu_token)"
FILES_JSON="$(curl -fsS -X GET \
  -H "Authorization: Bearer ${FEISHU_TOKEN}" \
  "https://open.feishu.cn/open-apis/drive/v1/files?folder_token=${FEISHU_FOLDER_TOKEN}")"

read -r FILE_NAME FILE_TOKEN < <(printf '%s' "$FILES_JSON" | choose_latest_deb_zip)
if [[ -z "${FILE_NAME:-}" || -z "${FILE_TOKEN:-}" ]]; then
  echo "No .deb.zip file found in folder"
  exit 1
fi

PKGVER="$(extract_version_from_name "$FILE_NAME")"
if [[ -z "$PKGVER" ]]; then
  echo "Cannot parse version from: $FILE_NAME"
  exit 1
fi

echo "Selected file: $FILE_NAME"
echo "Version: $PKGVER"

export GH_TOKEN
if gh release view "v${PKGVER}" >/dev/null 2>&1; then
  echo "Version ${PKGVER} already published, skipping build."
  exit 0
fi

echo "[2/5] Download outer zip and unpack .deb"
curl -fsS -X GET "https://open.feishu.cn/open-apis/drive/v1/files/${FILE_TOKEN}/download" \
  -H "Authorization: Bearer ${FEISHU_TOKEN}" \
  -o "$WORKDIR/source.zip"

mkdir -p "$WORKDIR/outer"
unzip -q "$WORKDIR/source.zip" -d "$WORKDIR/outer"

DEB_FILE="$(find "$WORKDIR/outer" -type f -name '*.deb' | sort | head -n1)"
if [[ -z "${DEB_FILE:-}" ]]; then
  echo "No .deb file found inside zip"
  exit 1
fi

PKG_FILE="$DEB_FILE"
PKG_BASENAME="$(basename "$PKG_FILE")"
PKG_SHA256="$(sha256sum "$PKG_FILE" | awk '{print $1}')"
PKG_DESC="Flix - 像聊天一样传文件. 跨平台文件传输工具，支持局域网内设备间快速分享文件。"
REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
ASSET_URL="${REPO_URL}/releases/download/v${PKGVER}/${PKG_BASENAME}"

echo "[3/5] Generate AUR PKGBUILD wrapper"
cat > "$AURGEN/PKGBUILD" <<EOF
# Maintainer: Origuchi <tobiichioriguchi@gmail.com>
pkgname=${AUR_PACKAGE_NAME}
pkgver=${PKGVER}
pkgrel=1
pkgdesc='${PKG_DESC}'
arch=('x86_64')
url='https://flix.center'
license=('custom:proprietary')
source=(
  "\${pkgname}-\${pkgver}.deb::${ASSET_URL}"
)
sha256sums=(
  '${PKG_SHA256}'
)
noextract=(
  "\${pkgname}-\${pkgver}.deb"
)

package() {
  cd "\$srcdir"
  bsdtar -xf "\${pkgname}-\${pkgver}.deb"
  bsdtar -xf data.tar.* -C "\$pkgdir"
}
EOF

cd "$AURGEN"

cat > .SRCINFO <<EOF
pkgbase = ${AUR_PACKAGE_NAME}
	pkgdesc = ${PKG_DESC}
	pkgver = ${PKGVER}
	pkgrel = 1
	url = https://flix.center
	arch = x86_64
	license = custom:proprietary
	source = ${AUR_PACKAGE_NAME}-${PKGVER}.deb::${ASSET_URL}
	sha256sums = ${PKG_SHA256}

pkgname = ${AUR_PACKAGE_NAME}
EOF

echo "[4/5] Publish GitHub Release"
export GH_TOKEN
if gh release view "v${PKGVER}" >/dev/null 2>&1; then
  gh release upload "v${PKGVER}" "$PKG_FILE" --clobber
else
  gh release create "v${PKGVER}" "$PKG_FILE" \
    --title "${AUR_PACKAGE_NAME} ${PKGVER}" \
    --notes "Automated build from Feishu folder ${FEISHU_FOLDER_TOKEN}"
fi

echo "[5/5] Push AUR package"
eval "\$(ssh-agent -s)"
install -d -m 700 ~/.ssh
printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
ssh-add ~/.ssh/id_ed25519
ssh-keyscan aur.archlinux.org >> ~/.ssh/known_hosts

rm -rf "$AURREPO"
git clone "ssh://aur@aur.archlinux.org/${AUR_PACKAGE_NAME}.git" "$AURREPO"
cd "$AURREPO"

cp "$AURGEN/PKGBUILD" .
cp "$AURGEN/.SRCINFO" .

git config user.name "$AUR_GIT_NAME"
git config user.email "$AUR_GIT_EMAIL"

git add PKGBUILD .SRCINFO
if git diff --cached --quiet; then
  echo "AUR repo already up to date"
else
  git commit -m "Update to ${PKGVER}"
  git push
fi

echo "Done."
