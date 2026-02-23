# GPD Win Max 2 Bazzite Suspend-then-Hibernate Setup

Automatically configures suspend-then-hibernate on GPD Win Max 2 running Bazzite (or other BTRFS-based systems).

## ⚠️ Experimental - Use at Your Own Risk

**This script is experimental and only tested on the GPD Win Max 2 2024 model.**

Using this script may prevent your system from booting. If something goes wrong:

- **On Bazzite/rpm-ostree systems**: You can boot into the previous working deployment from the bootloader menu to restore functionality
- On other systems, you may need to manually fix kernel parameters or fstab entries

**Proceed with caution and ensure you have a backup of important data.**

## What it does

1. Creates a swapfile matching your RAM size (required for hibernation)
2. Configures systemd to use suspend-then-hibernate with a 30-minute delay
3. Overrides lid close and power button actions to trigger suspend-then-hibernate
4. Automatically configures kernel parameters (`resume=` and `resume_offset=`) for hibernation

## Requirements

- BTRFS filesystem
- systemd-based distribution (Bazzite, Fedora, etc.)
- Root privileges

## Usage

```bash
# Standard run (idempotent - skips if already configured)
sudo ./activate_hibernation.sh

# Force reconfiguration even if already set up
sudo ./activate_hibernation.sh --force
```

## Idempotent Behavior

The script is fully idempotent and safe to run multiple times:

- Detects existing swapfile and skips recreation if size matches RAM
- Compares config files before writing to avoid unnecessary changes
- Checks kernel parameters before modifying bootloader
- Only runs `systemctl daemon-reload` if configs actually changed
- Never restarts `systemd-logind` (would crash GUI sessions)
- Rotates fstab backups, keeping the 10 most recent

### Early exit conditions

The script will exit early with "Already configured correctly!" if:

- Swapfile exists with correct size and is active
- All systemd configs are already in place
- Kernel parameters are correctly set
- `--force` flag is not used

## Backup Retention

- `/etc/fstab` backups are rotated on each modification
- 10 backups retained: `/etc/fstab.bak.1` through `/etc/fstab.bak.10`
- Oldest backup is deleted when rotation occurs

## What gets created

| File | Purpose |
|------|---------|
| `/var/swap/swapfile` | Swapfile for hibernation (BTRFS subvolume) |
| `/etc/systemd/sleep.conf.d/gpd-hibernate.conf` | Enables suspend-then-hibernate with 30min delay |
| `/etc/systemd/logind.conf.d/gpd-hibernate.conf` | Maps lid/power events to suspend-then-hibernate |
| `/etc/systemd/system/systemd-suspend.service.d/override.conf` | Redirects `systemctl suspend` to suspend-then-hibernate |

## Kernel Parameters

The script automatically detects your system type and configures kernel parameters:

### rpm-ostree systems (Bazzite, Fedora Silverblue, etc.)

Uses `rpm-ostree kargs` to append:
- `resume=UUID=<swap-uuid>`
- `resume_offset=<offset>`

### Traditional GRUB systems

Modifies `/etc/default/grub` and runs `grub-mkconfig`/`grub2-mkconfig`.

The UUID and resume offset are detected dynamically:
- UUID: `findmnt -no UUID -T /var/swap/swapfile`
- Offset: `btrfs inspect-internal map-swapfile -r /var/swap/swapfile`

## Testing

After running:

1. Close the lid, or
2. Run `systemctl suspend`

The system will suspend, then hibernate after 30 minutes of inactivity.

## Troubleshooting

### Hibernate doesn't work

- Ensure swapfile size matches or exceeds RAM
- Check kernel parameters: `cat /proc/cmdline | grep resume`
- Verify resume device: `cat /sys/power/resume`
- Confirm UUID matches: `findmnt -no UUID -T /var/swap/swapfile`
- Confirm offset: `btrfs inspect-internal map-swapfile -r /var/swap/swapfile`

### Kernel parameters not set

The script tries to detect your system type automatically. If it fails:

**For rpm-ostree (Bazzite):**
```bash
SWAP_UUID=$(findmnt -no UUID -T /var/swap/swapfile)
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /var/swap/swapfile)
rpm-ostree kargs --append-if-missing "resume=UUID=${SWAP_UUID}" --append-if-missing "resume_offset=${RESUME_OFFSET}"
```

**For GRUB:**
Add `resume=UUID=<uuid> resume_offset=<offset>` to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, then run `grub-mkconfig -o /boot/grub/grub.cfg`.

### Script crashes KDE/GUI

This was fixed in the current version. The script no longer restarts `systemd-logind`. If configs changed, a reboot is required for full effect.

## Changelog

### v3 (Current) - Kernel Parameter Support
- Added automatic kernel parameter configuration (`resume=`, `resume_offset=`)
- Dynamic UUID detection via `findmnt`
- Dynamic resume offset via `btrfs inspect-internal map-swapfile`
- Support for rpm-ostree systems (Bazzite, Silverblue)
- Support for traditional GRUB systems
- Idempotent kernel parameter checks before modifying

### v2 - Idempotent Rewrite
- Added `--force` flag to override idempotent checks
- Fixed swap size detection using `stat -c %s`
- Added config diff checking before writing
- Removed `systemctl restart systemd-logind` (was crashing KDE)
- Added backup rotation (keeps 10 backups)
- Only runs `daemon-reload` when configs change
- Early exit if already configured correctly

### v1 - Initial Release
- Basic swapfile creation
- Systemd config deployment
- Non-idempotent (always recreated everything)
