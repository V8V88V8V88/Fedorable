#!/usr/bin/env bash
set -euo pipefail

REPO=V8V88V8V88/Fedorable
BRANCH=${FEDORABLE_BRANCH:-main}
PREFIX=/opt/fedorable
BIN=/usr/local/bin/fedorable

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail 'Run the installer with sudo.'

if [[ ${1:-} == --uninstall ]]; then
    rm -rf -- "$PREFIX"
    [[ -L $BIN ]] && rm -f -- "$BIN"
    printf 'Fedorable removed.\n'
    exit 0
fi

command -v curl >/dev/null 2>&1 || fail 'curl is required.'
command -v tar >/dev/null 2>&1 || fail 'tar is required.'

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT

printf 'Downloading Fedorable (%s)...\n' "$BRANCH"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
    | tar -xz -C "$workdir" --strip-components=1

[[ -f $workdir/fedorable.sh && -d $workdir/lib ]] || fail 'Downloaded archive looks incomplete.'

rm -rf -- "$PREFIX"
mkdir -p -- "$PREFIX"
cp -r -- "$workdir/fedorable.sh" "$workdir/lib" "$workdir/config" "$workdir/LICENSE" "$PREFIX/"
chmod 755 "$PREFIX/fedorable.sh"
ln -sf -- "$PREFIX/fedorable.sh" "$BIN"

printf 'Installed. Run: fedorable\n'
