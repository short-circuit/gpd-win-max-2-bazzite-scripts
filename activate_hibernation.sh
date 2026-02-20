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

check_kernel_params() {
  local expected_uuid="$1"
  local expected_offset="$2"
  
  if command -v rpm-ostree &>/dev/null; then
    local current_kargs
    current_kargs=$(rpm-ostree kargs 2>/dev/null || echo "")
    if echo "$current_kargs" | grep -q "resume=UUID=${expected_uuid}" && \
       echo "$current_kargs" | grep -q "resume_offset=${expected_offset}"; then
      return 0
    fi
  elif [ -f /proc/cmdline ]; then
    if grep -q "resume=UUID=${expected_uuid}" /proc/cmdline && \
       grep -q "resume_offset=${expected_offset}" /proc/cmdline; then
      return 0
    fi
  fi
  return 1
}

KERNEL_PARAMS_NEEDED=false
SWAP_UUID=""
RESUME_OFFSET=""

if [ -f "/var/swap/swapfile" ]; then
  SWAP_UUID=$(findmnt -no UUID -T /var/swap/swapfile 2>/dev/null || echo "")
  RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /var/swap/swapfile 2>/dev/null || echo "")
  
  if [ -n "$SWAP_UUID" ] && [ -n "$RESUME_OFFSET" ]; then
    if [ "$FORCE" = true ]; then
      KERNEL_PARAMS_NEEDED=true
    elif ! check_kernel_params "$SWAP_UUID" "$RESUME_OFFSET"; then
      KERNEL_PARAMS_NEEDED=true
    fi
  fi
fi

if [ "$FORCE" = false ] && [ "$SWAP_ACTIVE" = true ] && [ "$SWAP_CORRECT_SIZE" = true ] && [ "$CONFIG_NEEDED" = false ] && [ "$KERNEL_PARAMS_NEEDED" = false ]; then
  echo "✅ Already configured correctly!"
  echo "   - Swap: ${RAM_GB}GB (active)"
  echo "   - Mode: Suspend-then-Hibernate"
  echo "   - Delay: 30 minutes"
  echo "   - Kernel params: resume=UUID=$SWAP_UUID resume_offset=$RESUME_OFFSET"
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

SWAP_UUID=$(findmnt -no UUID -T /var/swap/swapfile 2>/dev/null || echo "")
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /var/swap/swapfile 2>/dev/null || echo "")

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
fi

KERNEL_PARAMS_CHANGED=false

if [ -n "$SWAP_UUID" ] && [ -n "$RESUME_OFFSET" ]; then
  echo "🔧 Configuring kernel parameters for hibernation..."
  echo "   -> UUID: $SWAP_UUID"
  echo "   -> Resume offset: $RESUME_OFFSET"
  
  if [ "$FORCE" = true ] || ! check_kernel_params "$SWAP_UUID" "$RESUME_OFFSET"; then
    if command -v rpm-ostree &>/dev/null; then
      echo "   -> Detected rpm-ostree system (Bazzite/Silverblue)"
      rpm-ostree kargs \
        --append-if-missing "resume=UUID=${SWAP_UUID}" \
        --append-if-missing "resume_offset=${RESUME_OFFSET}"
      KERNEL_PARAMS_CHANGED=true
    elif [ -f /etc/default/grub ]; then
      echo "   -> Detected traditional GRUB system"
      rotate_backups "/etc/default/grub"
      
      sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 resume=UUID=${SWAP_UUID} resume_offset=${RESUME_OFFSET}\"/" /etc/default/grub
      
      sed -i 's/GRUB_CMDLINE_LINUX="\([^"]*\)resume=[^"]*"/GRUB_CMDLINE_LINUX="\1"/' /etc/default/grub
      sed -i 's/GRUB_CMDLINE_LINUX="\([^"]*\)resume_offset=[^"]*"/GRUB_CMDLINE_LINUX="\1"/' /etc/default/grub
      sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 resume=UUID=${SWAP_UUID} resume_offset=${RESUME_OFFSET}\"/" /etc/default/grub"
      sed -i 's/GRUB_CMDLINE_LINUX="  */GRUB_CMDLINE_LINUX="/' /etc/default/grub
      sed -i 's/  *"/"/' /etc/default/grub
      
      if command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
      elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
      fi
      KERNEL_PARAMS_CHANGED=true
    else
      echo "   ⚠️  WARNING: Could not detect bootloader type."
      echo "   Please manually add kernel parameters:"
      echo "   resume=UUID=${SWAP_UUID} resume_offset=${RESUME_OFFSET}"
    fi
  fi
else
  echo "   ⚠️  WARNING: Could not determine swap UUID or resume offset."
  echo "   Kernel parameters not configured. Hibernate may not work."
fi

echo ""
echo "✅ DONE!"
echo "   - Swap: ${RAM_GB}GB"
echo "   - Mode: Suspend-then-Hibernate"
echo "   - Delay: 30 minutes"

NEEDS_REBOOT=false
if [ "$CONFIG_CHANGED" = true ]; then
  NEEDS_REBOOT=true
fi
if [ "$KERNEL_PARAMS_CHANGED" = true ]; then
  NEEDS_REBOOT=true
fi

if [ "$NEEDS_REBOOT" = true ]; then
  echo "   - Action required: Reboot to activate all changes"
else
  echo "   You can test now by closing the lid or running 'systemctl suspend'"
fi
