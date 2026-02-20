#!/bin/bash
set -euo pipefail

# === GPD Win Max 2 Bazzite Suspend-Fix Script (Idempotent) ===

FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "This script requires root privileges to configure system settings."
  exec sudo "$0" "$@"
fi

echo "=== GPD Win Max 2 Suspend-then-Hibernate Setup ==="

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( (RAM_KB + 1048575) / 1048576 ))
echo "   -> Detected ${RAM_GB}GB RAM"

SWAP_ACTIVE=false
SWAP_CORRECT_SIZE=false

if [ -f "/var/swap/swapfile" ]; then
  CURRENT_SWAP_BYTES=$(stat -c %s "/var/swap/swapfile" 2>/dev/null || echo "0")
  CURRENT_SWAP_GB=$((CURRENT_SWAP_BYTES / 1073741824))
  if [ "$CURRENT_SWAP_GB" -eq "$RAM_GB" ]; then
    SWAP_CORRECT_SIZE=true
  fi
  if grep -q "/var/swap/swapfile" /proc/swaps 2>/dev/null; then
    SWAP_ACTIVE=true
  fi
fi

CONFIG_NEEDED=false

check_config_diff() {
  local new_content="$1"
  local target_file="$2"
  if [ ! -f "$target_file" ]; then
    return 1
  fi
  ! diff -q <(echo "$new_content") "$target_file" &>/dev/null
}

NEW_SLEEP_CONF="[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=30min"

NEW_LOGIND_CONF="[Login]
HandleSuspendKey=suspend-then-hibernate
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=suspend-then-hibernate
IdleAction=suspend-then-hibernate"

NEW_SUSPEND_OVERRIDE="[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-sleep suspend-then-hibernate"

if [ "$FORCE" = true ]; then
  CONFIG_NEEDED=true
else
  if check_config_diff "$NEW_SLEEP_CONF" "/etc/systemd/sleep.conf.d/gpd-hibernate.conf"; then
    CONFIG_NEEDED=true
  fi
  if check_config_diff "$NEW_LOGIND_CONF" "/etc/systemd/logind.conf.d/gpd-hibernate.conf"; then
    CONFIG_NEEDED=true
  fi
  if check_config_diff "$NEW_SUSPEND_OVERRIDE" "/etc/systemd/system/systemd-suspend.service.d/override.conf"; then
    CONFIG_NEEDED=true
  fi
fi

if [ "$FORCE" = false ] && [ "$SWAP_ACTIVE" = true ] && [ "$SWAP_CORRECT_SIZE" = true ] && [ "$CONFIG_NEEDED" = false ]; then
  echo "✅ Already configured correctly!"
  echo "   - Swap: ${RAM_GB}GB (active)"
  echo "   - Mode: Suspend-then-Hibernate"
  echo "   - Delay: 30 minutes"
  echo "   Use --force to reconfigure anyway."
  exit 0
fi

rotate_backups() {
  local target="$1"
  if [ -f "$target" ]; then
    if [ -f "${target}.bak.10" ]; then
      rm -f "${target}.bak.10"
    fi
    for i in $(seq 9 -1 1); do
      if [ -f "${target}.bak.$i" ]; then
        mv "${target}.bak.$i" "${target}.bak.$((i+1))"
      fi
    done
    cp "$target" "${target}.bak.1"
  fi
}

echo "🧹 Cleaning up existing swap..."

systemctl disable --now zram-swap.service 2>/dev/null || true
systemctl disable --now swap-create@zram0.service 2>/dev/null || true

swapoff -a 2>/dev/null || true

if grep -q "swap" /etc/fstab; then
  rotate_backups "/etc/fstab"
  sed -i '/swap/d' /etc/fstab
  echo "   -> Cleaned /etc/fstab"
fi

if [ "$FORCE" = true ] || [ "$SWAP_CORRECT_SIZE" = false ]; then
  rm -f /var/swap/swapfile 2>/dev/null || true
  if [ -d "/var/swap" ]; then
    if btrfs subvolume show /var/swap &>/dev/null; then
      btrfs subvolume delete /var/swap
    else
      rm -rf /var/swap
    fi
  fi
  echo "   -> Removed old swap artifacts"
fi

echo "💾 Creating new BTRFS swapfile (${RAM_GB}GB)..."

if [ ! -d "/var/swap" ]; then
  btrfs subvolume create /var/swap
fi

chmod 700 /var/swap

if [ ! -f "/var/swap/swapfile" ]; then
  if command -v btrfs &>/dev/null; then
    btrfs filesystem mkswapfile --size "${RAM_GB}G" /var/swap/swapfile
  else
    echo "   -> 'btrfs' command not found, using dd fallback..."
    truncate -s 0 /var/swap/swapfile
    chattr +C /var/swap/swapfile
    dd if=/dev/zero of=/var/swap/swapfile bs=1G count=$RAM_GB status=progress
    chmod 600 /var/swap/swapfile
    mkswap /var/swap/swapfile
  fi
fi

if ! grep -q "/var/swap/swapfile" /proc/swaps 2>/dev/null; then
  swapon /var/swap/swapfile
fi

if ! grep -q "^/var/swap/swapfile" /etc/fstab; then
  echo "/var/swap/swapfile none swap defaults 0 0" >> /etc/fstab
fi
echo "   -> Swap active!"

echo "⚙️  Configuring systemd sleep settings..."

CONFIG_CHANGED=false

mkdir -p /etc/systemd/sleep.conf.d
if [ ! -f "/etc/systemd/sleep.conf.d/gpd-hibernate.conf" ] || \
   [ "$FORCE" = true ] || \
   check_config_diff "$NEW_SLEEP_CONF" "/etc/systemd/sleep.conf.d/gpd-hibernate.conf"; then
  echo "$NEW_SLEEP_CONF" > /etc/systemd/sleep.conf.d/gpd-hibernate.conf
  CONFIG_CHANGED=true
fi

mkdir -p /etc/systemd/logind.conf.d
if [ ! -f "/etc/systemd/logind.conf.d/gpd-hibernate.conf" ] || \
   [ "$FORCE" = true ] || \
   check_config_diff "$NEW_LOGIND_CONF" "/etc/systemd/logind.conf.d/gpd-hibernate.conf"; then
  echo "$NEW_LOGIND_CONF" > /etc/systemd/logind.conf.d/gpd-hibernate.conf
  CONFIG_CHANGED=true
fi

mkdir -p /etc/systemd/system/systemd-suspend.service.d
if [ ! -f "/etc/systemd/system/systemd-suspend.service.d/override.conf" ] || \
   [ "$FORCE" = true ] || \
   check_config_diff "$NEW_SUSPEND_OVERRIDE" "/etc/systemd/system/systemd-suspend.service.d/override.conf"; then
  echo "$NEW_SUSPEND_OVERRIDE" > /etc/systemd/system/systemd-suspend.service.d/override.conf
  CONFIG_CHANGED=true
fi

if [ "$CONFIG_CHANGED" = true ]; then
  echo "🔄 Reloading systemd..."
  systemctl daemon-reload
  echo ""
  echo "⚠️  WARNING: logind.conf was modified."
  echo "   A reboot is required for changes to take full effect."
  echo "   (Restarting systemd-logind now would crash your GUI session.)"
fi

echo "✅ DONE!"
echo "   - Swap: ${RAM_GB}GB"
echo "   - Mode: Suspend-then-Hibernate"
echo "   - Delay: 30 minutes"
if [ "$CONFIG_CHANGED" = true ]; then
  echo "   - Action required: Reboot to activate all changes"
else
  echo "   You can test now by closing the lid or running 'systemctl suspend'"
fi
