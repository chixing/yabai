#!/usr/bin/env bash
# install-local.sh - install this fork's build of yabai in place of a Homebrew install.
#
# Signs a copy of bin/yabai, pins the passwordless `--load-sa` sudoers entry to its hash,
# swaps it into $PREFIX/bin, loads the scripting addition and restarts the launchd service.
# Nothing installed is touched until signing and the sudoers update have succeeded.
#
# Run via `make install-local` (which builds first). Honours:
#   PREFIX      install location       (default /opt/homebrew)
#   YABAI_CERT  code-signing identity  (default: first "Apple Development" identity, else yabai-cert)
#
# Signing with the same identity every time keeps the Accessibility grant across rebuilds.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  cat >&2 <<'EOF'
error: run this as your normal user, NOT with sudo (`make install-local`, not `sudo make ...`).
It elevates only the steps that need root and will prompt for your password.
Running the whole thing as root signs against root's keychain, writes a `root` sudoers
entry, and makes --load-sa look for the wrong per-user SA socket (SUDO_UID=0) -> it fails.
EOF
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/opt/homebrew}"
BIN_SRC="$root/bin/yabai"
BIN_DST="$PREFIX/bin/yabai"
MSG_SRC="$root/bin/yabai-msg"
MSG_DST="$PREFIX/bin/yabai-msg"
SUDOERS="/private/etc/sudoers.d/yabai"

if [ -z "${YABAI_CERT:-}" ]; then
  YABAI_CERT="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
  YABAI_CERT="${YABAI_CERT:-yabai-cert}"
fi

if [ "${1:-}" = "--uninstall" ]; then
  echo "==> uninstalling"
  "$BIN_DST" --stop-service 2>/dev/null || true
  "$BIN_DST" --uninstall-service 2>/dev/null || true
  sudo "$BIN_DST" --uninstall-sa 2>/dev/null || true
  rm -f "$BIN_DST" "$MSG_DST"
  sudo rm -f "$SUDOERS"
  echo "==> removed binary, service, scripting-addition, and sudoers entry"
  exit 0
fi

[ -x "$BIN_SRC" ] || { echo "error: $BIN_SRC not built — run 'make' first" >&2; exit 1; }

mkdir -p "$PREFIX/bin"
# same directory as $BIN_DST, so the final mv is an atomic rename
stage="$(mktemp "$PREFIX/bin/.yabai.XXXXXX")"
sudoers_tmp="$(mktemp)"
trap 'rm -f "$stage" "$sudoers_tmp"' EXIT

cp "$BIN_SRC" "$stage"
chmod 0755 "$stage"

echo "==> codesigning with '$YABAI_CERT'"
if ! codesign -fs "$YABAI_CERT" "$stage" 2>/dev/null; then
  cat >&2 <<EOF
error: code-signing identity '$YABAI_CERT' not found or unusable. Nothing was changed.
Pick one from \`security find-identity -v -p codesigning\` and re-run with YABAI_CERT=...
EOF
  exit 1
fi
codesign --verify "$stage"

echo "==> pinning $SUDOERS to the new binary's hash (asks for your password)"
hash="$(shasum -a 256 "$stage" | cut -d' ' -f1)"
printf '%s ALL=(root) NOPASSWD: sha256:%s %s --load-sa\n' "$(whoami)" "$hash" "$BIN_DST" > "$sudoers_tmp"
# sudo skips files in sudoers.d whose name contains a '.', so the staged copy is never live
sudo install -m 0440 -o root -g wheel "$sudoers_tmp" "$SUDOERS.new"
if ! sudo visudo -cf "$SUDOERS.new" >/dev/null; then
  sudo rm -f "$SUDOERS.new"
  echo "error: generated sudoers entry failed validation. Nothing was changed." >&2
  exit 1
fi
sudo mv -f "$SUDOERS.new" "$SUDOERS"

echo "==> installing $BIN_DST"
"$BIN_DST" --stop-service 2>/dev/null || true
mv -f "$stage" "$BIN_DST"
if [ -x "$MSG_SRC" ]; then
  install -m 0755 "$MSG_SRC" "$MSG_DST"
fi

echo "==> loading scripting addition"
sudo "$BIN_DST" --load-sa

echo "==> starting launchd service"
"$BIN_DST" --start-service

echo
echo "==> done. $("$BIN_DST" --version) signed with '$YABAI_CERT' at $BIN_DST"
if [ -d "$PREFIX/Cellar/yabai" ]; then
  echo "    A Homebrew yabai is still installed; run 'brew uninstall yabai' so it can't replace this build."
fi
