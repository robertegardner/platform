#!/usr/bin/env bash
# backup-terraform.sh — snapshot thebeast's terraform.tfvars + tfstate (which
# live ONLY on thebeast, the Proxmox HOST, and have no other backup) to THIS VM
# (codeserver, a cluster-backed-up guest). Run FROM codeserver. Rotates snapshots.
#
# Restore: copy the wanted snapshot's files back to thebeast's terraform dir, e.g.
#   scp ~/platform-tf-backup/latest/terraform.tfvars deploy@192.168.6.163:/home/deploy/platform/terraform/
#
# These files contain secrets (Proxmox token, Icecast passwords) — kept mode 600
# in a mode-700 dir. (Optional hardening: gpg/age-encrypt the snapshot.)
set -euo pipefail

THEBEAST="${THEBEAST:-deploy@192.168.6.163}"
SRC="${SRC:-/home/deploy/platform/terraform}"
DEST="${DEST:-$HOME/platform-tf-backup}"
KEEP="${KEEP:-20}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILES=(terraform.tfvars terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl)

mkdir -p "$DEST"; chmod 700 "$DEST"
snap="$DEST/$STAMP"; mkdir -p "$snap"; chmod 700 "$snap"

n=0
for f in "${FILES[@]}"; do
  if ssh -o BatchMode=yes "$THEBEAST" "test -f '$SRC/$f'" 2>/dev/null; then
    scp -q "$THEBEAST:$SRC/$f" "$snap/$f"
    chmod 600 "$snap/$f"
    n=$((n + 1))
  else
    echo "  (skip: $f not on thebeast)"
  fi
done

# 'latest' convenience symlink + integrity note (sha256 of tfvars, not its contents).
ln -sfn "$STAMP" "$DEST/latest"
sha=$(sha256sum "$snap/terraform.tfvars" 2>/dev/null | cut -c1-16 || echo "n/a")

# Rotate: keep the newest $KEEP timestamped snapshots.
ls -1dt "$DEST"/2*/ 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -rf

echo "backed up $n files -> $snap  (tfvars sha256:$sha)"
ls -l "$snap" | awk 'NR>1{printf "  %s %6s %s\n",$1,$5,$NF}'
echo "snapshots kept: $(ls -1d "$DEST"/2*/ 2>/dev/null | wc -l) (KEEP=$KEEP)"
