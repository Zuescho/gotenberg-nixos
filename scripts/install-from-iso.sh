#!/usr/bin/env bash
# Partition a Hyper-V Generation 2 disk and install this flake.
# Run from the NixOS minimal ISO after editing hosts/gotenberg/site.nix.
#
#   CONFIRM=yes DISK=/dev/sda REPO=/root/gotenberg-nixos \
#     bash /root/gotenberg-nixos/scripts/install-from-iso.sh
set -euo pipefail

DISK="${DISK:-/dev/sda}"
REPO="${REPO:-/root/gotenberg-nixos}"
CONFIRM="${CONFIRM:-}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this as root from the NixOS installer." >&2
  exit 1
fi

if [[ ! -f "${REPO}/flake.nix" || ! -f "${REPO}/hosts/gotenberg/site.nix" ]]; then
  echo "REPO=${REPO} does not look like this repository." >&2
  exit 1
fi

if grep -q 'REPLACE_ME' "${REPO}/hosts/gotenberg/site.nix"; then
  echo "Edit ${REPO}/hosts/gotenberg/site.nix and replace the SSH key before installing." >&2
  exit 1
fi

if [[ "${CONFIRM}" != "yes" ]]; then
  echo "This erases ${DISK} and installs NixOS. Re-run with CONFIRM=yes after checking lsblk." >&2
  exit 1
fi

if [[ ! -b "${DISK}" ]]; then
  echo "Not a block device: ${DISK}" >&2
  exit 1
fi

if findmnt -n -o TARGET "${DISK}" >/dev/null 2>&1; then
  echo "${DISK} is mounted. Refusing to partition it." >&2
  exit 1
fi

echo "Disks currently visible:"
lsblk -o NAME,SIZE,TYPE,TRAN,LABEL,MOUNTPOINTS

install -d -m 0755 /etc/nix
if ! grep -q 'experimental-features' /etc/nix/nix.conf 2>/dev/null; then
  printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
fi
export NIX_CONFIG="experimental-features = nix-command flakes"

echo "Partitioning ${DISK} (GPT, 512 MiB ESP, rest root)"
parted -s "${DISK}" -- \
  mklabel gpt \
  mkpart ESP fat32 1MiB 512MiB \
  set 1 esp on \
  mkpart root ext4 512MiB 100%
partprobe "${DISK}" || true
sleep 2

if [[ -b "${DISK}p1" && -b "${DISK}p2" ]]; then
  BOOT="${DISK}p1"
  ROOT="${DISK}p2"
elif [[ -b "${DISK}1" && -b "${DISK}2" ]]; then
  BOOT="${DISK}1"
  ROOT="${DISK}2"
else
  echo "Could not find the new partitions on ${DISK}." >&2
  lsblk "${DISK}" >&2 || true
  exit 1
fi

mkfs.fat -F 32 -n NIXBOOT "${BOOT}"
mkfs.ext4 -F -L NIXROOT "${ROOT}"

umount -R /mnt >/dev/null 2>&1 || true
mount "${ROOT}" /mnt
mkdir -p /mnt/boot
mount "${BOOT}" /mnt/boot

rm -rf /mnt/etc/nixos
mkdir -p /mnt/etc
cp -a "${REPO}" /mnt/etc/nixos
# autoUpgrade commits lockfile updates in this checkout.
if [[ -d /mnt/etc/nixos/.git ]] && command -v git >/dev/null 2>&1; then
  git config --global --add safe.directory /mnt/etc/nixos || true
fi

echo "Installing NixOS from ${REPO}"
nixos-install --root /mnt --flake "/mnt/etc/nixos#gotenberg" --no-root-passwd \
  --option experimental-features "nix-command flakes"

echo
echo "Install finished."
echo "1. Shut the VM down and remove the ISO (see docs/hyperv-setup.md)."
echo "2. Start the VM and SSH in as the admin user."
echo "3. curl http://127.0.0.1:3000/health"
echo "   and the phase 1 URL from hosts/gotenberg/site.nix."
