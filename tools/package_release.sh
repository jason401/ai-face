#!/bin/zsh
# Make the source installation ZIP for a release tag (like AI Illuminati): the published files of
# that tag only (git archive: no .git, no ignored or locally excluded files), plus SHA256SUMS.txt.
# Never builds, installs or signs anything. Usage: zsh tools/package_release.sh v2.2.0 [out-dir]
set -eu
cd "${0:A:h}/.."
TAG="${1:?usage: package_release.sh <tag> [out-dir]}"
OUT="${2:-$PWD/release-artifacts}"
[[ "$TAG" == v<->.<->.<-> ]] || { echo "Tag must look like v2.2.0" >&2; exit 2; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "No tag $TAG" >&2; exit 2; }
VERSION="${TAG#v}"
git show "${TAG}:Install AI Face.command" | grep -qx "RELEASE_TAG='$TAG'" \
  || { echo "Install AI Face.command RELEASE_TAG does not match $TAG" >&2; exit 2; }
git show "${TAG}:tools/build_app.sh" | grep -q "<string>$VERSION</string>" \
  || { echo "build_app.sh version does not match $TAG" >&2; exit 2; }
mkdir -p "$OUT"
NAME="AI-Face-$VERSION-source.zip"
git archive --format=zip --prefix="AI-Face-$VERSION-source/" -o "$OUT/$NAME" "$TAG"
# Conservative secret scan of the archive's files (not a full security audit).
if git grep -I -l -E -e '-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----' -e 'gh[pousr]_[A-Za-z0-9]{30,}' \
     -e 'github_pat_[A-Za-z0-9_]{40,}' -e 'sk-(ant-|proj-)[A-Za-z0-9_-]{30,}' "$TAG" -- . ':!tools/package_release.sh'; then
  rm -f "$OUT/$NAME"; echo "Possible secret found; not packaged." >&2; exit 1
fi
(cd "$OUT"; /usr/bin/shasum -a 256 "$NAME" > SHA256SUMS.txt)
echo "Created $OUT/$NAME ($(git rev-parse "$TAG^{commit}"))"
