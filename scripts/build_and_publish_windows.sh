#!/usr/bin/env bash
# scripts/build_and_publish_windows.sh
set -uo pipefail

: "${FEISHU_APP_ID:?missing FEISHU_APP_ID}"
: "${FEISHU_APP_SECRET:?missing FEISHU_APP_SECRET}"
: "${FEISHU_WIN_FOLDER_TOKEN:?missing FEISHU_WIN_FOLDER_TOKEN}"
: "${SCOOP_SSH_PRIVATE_KEY:?missing SCOOP_SSH_PRIVATE_KEY}"
: "${SCOOP_GIT_NAME:?missing SCOOP_GIT_NAME}"
: "${SCOOP_GIT_EMAIL:?missing SCOOP_GIT_EMAIL}"
: "${GH_TOKEN:?missing GH_TOKEN}"
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"

ROOT="${GITHUB_WORKSPACE:-$PWD}"
WORKDIR="$ROOT/.ci-work-windows"
SCOOPREPO="$WORKDIR/scoop-repo"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

get_feishu_token() {
  curl -fsS -X POST \
    "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg id "${FEISHU_APP_ID}" --arg secret "${FEISHU_APP_SECRET}" \
      '{app_id:$id, app_secret:$secret}')" \
  | jq -r '.tenant_access_token'
}

choose_latest_win_zip() {
  jq -r '
    .data.files
    | map(select(.name | test("-portable\\.zip$")))
    | sort_by(.modified_time | tonumber)
    | last
    | [.name, .token, .modified_time]
    | @tsv
  '
}

extract_version_from_name() {
  local name="$1"
  if [[ "$name" =~ Flix-Windows-([0-9][A-Za-z0-9._-]*)-portable\.zip$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "Cannot parse version from: $name" >&2
    exit 1
  fi
}

echo "[1/5] Query Feishu Windows folder and check version"
FEISHU_TOKEN="$(get_feishu_token)"
FILES_JSON="$(curl -fsS -X GET \
  -H "Authorization: Bearer ${FEISHU_TOKEN}" \
  "https://open.feishu.cn/open-apis/drive/v1/files?folder_token=${FEISHU_WIN_FOLDER_TOKEN}")"

read -r FILE_NAME FILE_TOKEN MODIFIED_TIME < <(printf '%s' "$FILES_JSON" | choose_latest_win_zip)
if [[ -z "${FILE_NAME:-}" || -z "${FILE_TOKEN:-}" || -z "${MODIFIED_TIME:-}" ]]; then
  echo "No -portable.zip file found in folder"
  exit 1
fi

PKGVER="$(extract_version_from_name "$FILE_NAME")"
if [[ -z "$PKGVER" ]]; then
  exit 1
fi

echo "Selected file: $FILE_NAME"
echo "Version: $PKGVER"

export GH_TOKEN
PKGREL=1
RELEASE_TAG="windows-v${PKGVER}"

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "Version $RELEASE_TAG exists on GitHub."
  RELEASE_BODY=$(gh release view "$RELEASE_TAG" --json body -q .body)
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
  echo "Version $RELEASE_TAG is new. Proceeding with build."
fi

echo "[2/5] Download Windows portable zip"
curl -fsS -X GET "https://open.feishu.cn/open-apis/drive/v1/files/${FILE_TOKEN}/download" \
  -H "Authorization: Bearer ${FEISHU_TOKEN}" \
  -o "$WORKDIR/$FILE_NAME"

PKG_FILE="$WORKDIR/$FILE_NAME"
PKG_BASENAME="$FILE_NAME"
PKG_SHA256="$(sha256sum "$PKG_FILE" | awk '{print $1}')"
REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
ASSET_URL="${REPO_URL}/releases/download/${RELEASE_TAG}/${PKG_BASENAME}"

echo "[3/5] Publish GitHub Release for Windows"
RELEASE_NOTES="Automated Windows build from Feishu folder ${FEISHU_WIN_FOLDER_TOKEN}

<!-- tracking: {\"modified_time\": \"${MODIFIED_TIME}\", \"pkgrel\": ${PKGREL}} -->"

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release upload "$RELEASE_TAG" "$PKG_FILE" --clobber
  gh release edit "$RELEASE_TAG" --notes "$RELEASE_NOTES"
else
  gh release create "$RELEASE_TAG" "$PKG_FILE" \
    --title "Flix Windows ${PKGVER}" \
    --notes "$RELEASE_NOTES"
fi

echo "[4/5] Generate Scoop App Manifest"
mkdir -p "$WORKDIR/manifest"
cat > "$WORKDIR/manifest/flix.json" <<EOF
{
    "version": "${PKGVER}-${PKGREL}",
    "description": "Flix - 像聊天一样传文件. 跨平台文件传输工具，支持局域网内设备间快速分享文件。",
    "homepage": "https://flix.center",
    "license": "Freeware",
    "architecture": {
        "64bit": {
            "url": "${ASSET_URL}",
            "hash": "${PKG_SHA256}"
        }
    }
}
EOF

echo "[5/5] Push to Scoop Bucket Repo"
eval "$(ssh-agent -s)"
install -d -m 700 ~/.ssh
printf '%s\n' "$SCOOP_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
ssh-add ~/.ssh/id_ed25519
ssh-keyscan github.com >> ~/.ssh/known_hosts

rm -rf "$SCOOPREPO"
git clone "ssh://git@github.com/Tobiichi-Origuchi/flix.git" "$SCOOPREPO"
cd "$SCOOPREPO"

cp "$WORKDIR/manifest/flix.json" ./bucket/

git config user.name "$SCOOP_GIT_NAME"
git config user.email "$SCOOP_GIT_EMAIL"

git add ./bucket/flix.json
if git diff --cached --quiet; then
  echo "Scoop bucket already up to date"
else
  git commit -m "Update Flix Windows to ${PKGVER}-${PKGREL}"
  git push
fi

echo "Done."
