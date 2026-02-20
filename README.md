# GPD Win Max 2 Bazzite Suspend-then-Hibernate Setup

Automatically configures suspend-then-hibernate on GPD Win Max 2 running Bazzite (or other BTRFS-based systems).

## What it does

1. Creates a swapfile matching your RAM size (required for hibernation)
2. Configures systemd to use suspend-then-hibernate with a 30-minute delay
3. Overrides lid close and power button actions to trigger suspend-then-hibernate

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
- Only runs `systemctl daemon-reload` if configs actually changed
- Never restarts `systemd-logind` (would crash GUI sessions)
- Rotates fstab backups, keeping the 10 most recent

### Early exit conditions

The script will exit early with "Already configured correctly!" if:

- Swapfile exists with correct size and is active
- All systemd configs are already in place
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

## Testing

After running:

1. Close the lid, or
2. Run `systemctl suspend`

The system will suspend, then hibernate after 30 minutes of inactivity.

## Troubleshooting

### Hibernate doesn't work

- Ensure swapfile size matches or exceeds RAM
- Check `cat /sys/power/resume` shows the correct swap device
- Verify kernel parameters include `resume=` pointing to swap

### Script crashes KDE/GUI

This was fixed in the current version. The script no longer restarts `systemd-logind`. If configs changed, a reboot is required for full effect.

## Changelog

### v2 (Current) - Idempotent Rewrite
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
