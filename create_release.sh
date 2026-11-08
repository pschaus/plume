#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
VERSION="${VERSION#v}"
TAG="v${VERSION}"

echo "🍎 ============================================================="
echo "🍎 Plume $TAG — Preparing Release & Triggering GitHub Actions CI"
echo "🍎 ============================================================="

# 1. Sync VERSION file & Info.plist
echo "$VERSION" > VERSION
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

# 2. Extract Changelog notes for this version
NOTES=$(awk "/^## \\[$VERSION\\]/{flag=1; next} /^## \\[/{flag=0} flag" CHANGELOG.md)
if [ -z "$NOTES" ]; then
    NOTES="Release Plume $TAG"
fi

# 3. Update website/version.json
python3 - "$VERSION" "$TAG" "$NOTES" << 'EOF'
import json, sys, datetime
version, tag, notes = sys.argv[1], sys.argv[2], sys.argv[3].strip()
path = "website/version.json"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["version"] = version
data["name"] = f"Plume {tag}"
data["title"] = f"Plume {tag}"
data["published_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
data["notes"] = notes
data["html_url"] = f"https://github.com/pschaus/plume/releases/tag/{tag}"
data["assets"]["macos"] = f"https://github.com/pschaus/plume/releases/latest/download/Plume_{version}_universal.dmg"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF

cp Resources/PlumeLogo.png website/logo.png

# 4. Sync website/* to gh-pages branch
echo "🌐 Updating gh-pages branch..."
WORKTREE_TMP="$(mktemp -d)"
cp -R website/* "$WORKTREE_TMP/"
cp Resources/PlumeLogo.png "$WORKTREE_TMP/logo.png"
touch "$WORKTREE_TMP/.nojekyll"
pushd "$WORKTREE_TMP" >/dev/null
git init
git config user.name "pschaus"
git config user.email "pschaus@users.noreply.github.com"
git checkout -b gh-pages
git add .
git commit -m "docs: update website & version.json for $TAG"
git remote add origin https://github.com/pschaus/plume.git
git push -u origin gh-pages --force
popd >/dev/null
rm -rf "$WORKTREE_TMP"

# 5. Commit and push main & tag to trigger GitHub Actions Notarized Build
echo "📦 Committing & pushing $TAG to origin..."
git add VERSION CHANGELOG.md README.md Package.swift build_and_install.sh create_release.sh generate_icon.swift Sources/ Resources/ website/ .github/
git commit -m "chore(release): Plume $TAG" || true
git tag -a "$TAG" -m "Plume $TAG" -f
git push origin main
git push origin "$TAG" --force

echo "🚀 Triggered GitHub Actions workflow for $TAG!"
echo "   https://github.com/pschaus/plume/actions"
