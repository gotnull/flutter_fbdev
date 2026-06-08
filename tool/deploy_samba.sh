#!/usr/bin/env bash
# deploy_samba.sh - copy a flutter_fbdev bundle onto a handheld over its Samba
# share. Samba is the reliable transport on these devices: Dropbear ships no
# scp/sftp and chokes on long SSH commands, but SMB file copies just work.
#
# Every step is timeout-capped so a flaky-Wi-Fi moment can't lock the script up,
# and copies are verified by size after a fresh remount.
#
# Usage:
#   tool/deploy_samba.sh <bundle-dir> [remote-subdir]
#
# Env: FBDEV_IP=192.168.0.x  FBDEV_USER=root  FBDEV_PASS=linux  FBDEV_SHARE=share
#      FBDEV_DEST=roms/ports/myapp   (path under the share root; default below)
set -euo pipefail

BUNDLE="${1:?usage: deploy_samba.sh <bundle-dir> [remote-subdir]}"
DEST="${2:-${FBDEV_DEST:-roms/ports/flutter_fbdev}}"
IP="${FBDEV_IP:?set FBDEV_IP to the device IP}"
USER="${FBDEV_USER:-root}"
PASS="${FBDEV_PASS:-linux}"
SHARE="${FBDEV_SHARE:-share}"
MP="${TMPDIR:-/tmp}/flutter-fbdev-smb"

to()   { perl -e 'alarm shift; exec @ARGV' "$@"; }   # timeout wrapper (portable)
mnt()  { mkdir -p "$MP"; to 8 umount "$MP" 2>/dev/null || true; to 25 mount_smbfs "//${USER}:${PASS}@${IP}/${SHARE}" "$MP"; }
umnt() { sync; to 8 umount "$MP" 2>/dev/null || true; }

[ -d "$BUNDLE" ] || { echo "no bundle dir: $BUNDLE" >&2; exit 1; }

echo "› mounting //${IP}/${SHARE}"
mnt || { echo "!! mount failed (Samba/Wi-Fi down?)" >&2; exit 1; }
mkdir -p "$MP/$DEST"

echo "› copying bundle → $DEST (be patient on the engine ~20MB)"
for f in "$BUNDLE"/* "$BUNDLE"/.[!.]*; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  if [ -d "$f" ]; then to 200 cp -Rf "$f" "$MP/$DEST/"; else to 200 cp -f "$f" "$MP/$DEST/$base"; fi
done
umnt

echo "› verifying (remount)"
mnt || { echo "!! remount failed" >&2; exit 1; }
ok=1
for f in "$BUNDLE"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"; want="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")"
  got="$(to 30 stat -f%z "$MP/$DEST/$b" 2>/dev/null || to 30 stat -c%s "$MP/$DEST/$b" 2>/dev/null || echo 0)"
  [ "$got" = "$want" ] || { echo "  ✗ $b ($got/$want)"; ok=0; }
done
umnt
[ "$ok" = 1 ] && echo "✓ deployed to ${IP}:/${SHARE}/${DEST}" || { echo "!! verify failed - re-run" >&2; exit 1; }
