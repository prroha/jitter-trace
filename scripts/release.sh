#!/usr/bin/env bash
# Release jitter-trace: bump the version, run the suites, tag, publish a GitHub
# release, then point the Homebrew formula at the new tarball.
#
#   scripts/release.sh 1.0.1
#   scripts/release.sh patch            # or minor, major
#   scripts/release.sh patch --dry-run  # say what would happen, change nothing
#
# The tap lives in its own repository; set TAP_DIR if it is not beside this one.
set -u

REPO="prroha/jitter-trace"
TAP_DIR="${TAP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/homebrew-tap}"
FORMULA_PATH="Formula/jitter-trace.rb"
TARBALL_WAIT_SECONDS=60
TARBALL_POLL_SECONDS=3

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

dry_run=0
requested=""

for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=1 ;;
    -h|--help)
      sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) requested="$argument" ;;
  esac
done

die() {
  printf "release: %s\n" "$1" >&2
  exit 1
}

step() {
  printf "\n▸ %s\n" "$1"
}

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf "  would run: %s\n" "$*"
    return 0
  fi
  "$@"
}

current_version() {
  awk -F'"' '/^VERSION=/ { print $2; exit }' bin/jitter-trace
}

# "1.2.3" plus patch|minor|major -> the next version.
bump_version() {
  awk -v version="$1" -v part="$2" 'BEGIN {
    split(version, n, ".")
    if (part == "major") { printf "%d.0.0", n[1] + 1 }
    else if (part == "minor") { printf "%d.%d.0", n[1], n[2] + 1 }
    else { printf "%d.%d.%d", n[1], n[2], n[3] + 1 }
  }'
}

valid_version() {
  awk -v version="$1" 'BEGIN { exit !(version ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) }'
}

[ -n "$requested" ] || die "say which version: a number like 1.0.1, or patch, minor or major."

from_version="$(current_version)"
[ -n "$from_version" ] || die "could not read VERSION from bin/jitter-trace."

case "$requested" in
  patch|minor|major) to_version="$(bump_version "$from_version" "$requested")" ;;
  *) to_version="$requested" ;;
esac
valid_version "$to_version" || die "$to_version is not a version like 1.0.1."

printf "releasing %s -> %s%s\n" "$from_version" "$to_version" \
  "$([ "$dry_run" -eq 1 ] && printf " (dry run)")"

step "checks"
command -v gh >/dev/null 2>&1 || die "gh (the GitHub CLI) is required."
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "release from main."
[ -z "$(git status --porcelain)" ] || die "commit or stash your changes first."
git fetch --quiet --tags origin || die "could not reach origin."
if git rev-parse "v$to_version" >/dev/null 2>&1; then
  die "tag v$to_version already exists."
fi
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "push main first; it differs from origin."
printf "  on main, clean, tag is free\n"

step "tests"
bash test/parse.test.sh >/dev/null || die "unit tests failed."
bash test/cli.test.sh >/dev/null || die "cli tests failed."
printf "  both suites pass\n"

step "version"
if [ "$dry_run" -eq 1 ]; then
  printf "  would set VERSION=\"%s\" in bin/jitter-trace\n" "$to_version"
else
  tmp="$(mktemp)"
  awk -v version="$to_version" '
    /^VERSION=/ { print "VERSION=\"" version "\""; next }
    { print }
  ' bin/jitter-trace > "$tmp" && mv "$tmp" bin/jitter-trace
  chmod +x bin/jitter-trace
  [ "$(current_version)" = "$to_version" ] || die "could not update VERSION."
  printf "  VERSION is now %s\n" "$to_version"
fi

step "commit and tag"
run git add bin/jitter-trace
run git commit -q -m "Release $to_version"
run git tag -a "v$to_version" -m "jitter-trace $to_version"
run git push -q origin main
run git push -q origin "v$to_version"

step "github release"
run gh release create "v$to_version" --repo "$REPO" \
  --title "jitter-trace $to_version" --generate-notes

step "formula"
tarball="https://github.com/$REPO/archive/refs/tags/v$to_version.tar.gz"
if [ "$dry_run" -eq 1 ]; then
  printf "  would checksum %s\n  would update %s/%s\n" "$tarball" "$TAP_DIR" "$FORMULA_PATH"
  printf "\ndry run finished; nothing changed.\n"
  exit 0
fi

# The tag's tarball appears a moment after the push.
checksum=""
waited=0
while [ "$waited" -lt "$TARBALL_WAIT_SECONDS" ]; do
  checksum="$(curl -fsSL "$tarball" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  case "$checksum" in
    [0-9a-f]*) break ;;
  esac
  sleep "$TARBALL_POLL_SECONDS"
  waited=$((waited + TARBALL_POLL_SECONDS))
done
[ -n "$checksum" ] || die "could not download $tarball to checksum it."
printf "  sha256 %s\n" "$checksum"

if [ ! -d "$TAP_DIR/.git" ]; then
  printf "  no tap at %s. Update the formula by hand:\n" "$TAP_DIR"
  printf "    url \"%s\"\n    sha256 \"%s\"\n" "$tarball" "$checksum"
  exit 0
fi

formula="$TAP_DIR/$FORMULA_PATH"
[ -f "$formula" ] || die "no formula at $formula."
tmp="$(mktemp)"
awk -v url="$tarball" -v sha="$checksum" '
  /^  url / { print "  url \"" url "\""; next }
  /^  sha256 / { print "  sha256 \"" sha "\""; next }
  { print }
' "$formula" > "$tmp" && mv "$tmp" "$formula"
grep -q "$checksum" "$formula" || die "the formula did not pick up the new checksum."

git -C "$TAP_DIR" add "$FORMULA_PATH"
git -C "$TAP_DIR" commit -q -m "jitter-trace $to_version"
git -C "$TAP_DIR" push -q

printf "\nreleased %s\n" "$to_version"
printf "  release   https://github.com/%s/releases/tag/v%s\n" "$REPO" "$to_version"
printf "  install   brew update && brew upgrade jitter-trace\n"
