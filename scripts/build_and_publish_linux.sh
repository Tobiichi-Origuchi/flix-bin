#!/usr/bin/env bash
# scripts/build_and_publish_linux.sh
set -euo pipefail

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
    | [.name, .token, .modified_time]
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

read -r FILE_NAME FILE_TOKEN MODIFIED_TIME < <(printf '%s' "$FILES_JSON" | choose_latest_deb_zip)
if [[ -z "${FILE_NAME:-}" || -z "${FILE_TOKEN:-}" || -z "${MODIFIED_TIME:-}" ]]; then
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
PKGREL=1

if gh release view "v${PKGVER}" >/dev/null 2>&1; then
  echo "Version ${PKGVER} exists on GitHub."
  RELEASE_BODY=$(gh release view "v${PKGVER}" --json body -q .body)
  TRACKING_JSON=$(echo "$RELEASE_BODY" | grep -oP '(?<=<!-- tracking: ).*(?= -->)' || true)

  if [[ -n "$TRACKING_JSON" ]]; then
    PREV_MOD_TIME=$(echo "$TRACKING_JSON" | jq -r .modified_time)
    PREV_PKGREL=$(echo "$TRACKING_JSON" | jq -r .pkgrel)

    if [[ "$MODIFIED_TIME" == "$PREV_MOD_TIME" ]]; then
      echo "File has not been modified (mtime: $MODIFIED_TIME). Skipping build."
      exit 0
    else
      echo "File has been silently modified by upstream (mtime: $PREV_MOD_TIME -> $MODIFIED_TIME). Bumping pkgrel."
      if [[ "$PREV_PKGREL" =~ ^[0-9]+$ ]]; then
        PKGREL=$((PREV_PKGREL + 1))
      else
        PKGREL=2
      fi
    fi
  else
    echo "No tracking info found in existing release. Forcing rebuild with bumped pkgrel."
    PKGREL=2
  fi
else
  echo "Version ${PKGVER} is new. Proceeding with build."
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
pkgrel=${PKGREL}
pkgdesc='${PKG_DESC}'
arch=('x86_64')
url='https://flix.center'
license=('LicenseRef-Flix-Proprietary')
depends=('libkeybinder3' 'libappindicator' 'libnotify')
conflicts=('flix-bin')
replaces=('flix-bin')
source=(
  "Flix-Linux-\${pkgver}.deb::${ASSET_URL}"
)
sha256sums=(
  '${PKG_SHA256}'
)

package() {
  bsdtar -xf data.tar.zst -C "\$pkgdir"
  install -Dm644 "\$pkgdir/opt/flix/data/flutter_assets/assets/data/flix_privacy.md" "\$pkgdir/usr/share/licenses/\${pkgname}/flix_privacy.md"
  install -d "\$pkgdir/usr/bin"
  ln -s /opt/flix/flix "\$pkgdir/usr/bin/flix"
  sed -i \\
    -e "s/Icon=com.ifreedomer.flix/Icon=flix/" \\
    -e "s/Exec=flix %F/Exec=\/opt\/flix\/flix %F/" \\
    "\$pkgdir/usr/share/applications/flix-send.desktop"
  rm -rf \\
    "\$pkgdir/opt/flix/data/flutter_assets/assets/data/flix-firewall-gui.exe" \\
    "\$pkgdir/opt/flix/data/flutter_assets/assets/data/flix-firewall.exe" \\
    "\$pkgdir/usr/lib/" \\
    "\$pkgdir/usr/local/"
}
EOF

cd "$AURGEN"

cat > .SRCINFO <<EOF
pkgbase = ${AUR_PACKAGE_NAME}
	pkgdesc = ${PKG_DESC}
	pkgver = ${PKGVER}
	pkgrel = ${PKGREL}
	url = https://flix.center
	arch = x86_64
	license = LicenseRef-Flix-Proprietary
	depends = libkeybinder3
	depends = libappindicator
	depends = libnotify
	conflicts = flix-bin
	replaces = flix-bin
	source = Flix-Linux-${PKGVER}.deb::${ASSET_URL}
	sha256sums = ${PKG_SHA256}

pkgname = ${AUR_PACKAGE_NAME}
EOF

echo "[4/5] Publish GitHub Release"
export GH_TOKEN
RELEASE_NOTES="Fetch from Feishu folder ${FEISHU_FOLDER_TOKEN}

<!-- tracking: {\"modified_time\": \"${MODIFIED_TIME}\", \"pkgrel\": ${PKGREL}} -->"

if gh release view "v${PKGVER}" >/dev/null 2>&1; then
  gh release upload "v${PKGVER}" "$PKG_FILE" --clobber
  gh release edit "v${PKGVER}" --notes "$RELEASE_NOTES"
else
  gh release create "v${PKGVER}" "$PKG_FILE" \
    --title "Flix Linux ${PKGVER}" \
    --notes "$RELEASE_NOTES"
fi

echo "[5/5] Push AUR package"
eval "$(ssh-agent -s)"
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
  git commit -m "Update to ${PKGVER}-${PKGREL}"
  git push
fi

echo "Done."
