# 🔄 Backup Proxmox PBS & PVE System Files

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.4+-blue.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Proxmox-PVE%20%7C%20PBS-green.svg)](https://www.proxmox.com/)
[![💖 Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-pink?logo=github)](https://github.com/sponsors/tis24dev)
[![☕ Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-tis24dev-yellow?logo=buymeacoffee)](https://buymeacoffee.com/tis24dev)

**Professional backup system for Proxmox Virtual Environment (PVE) and Proxmox Backup Server (PBS) settings and config and critical files** with advanced compression features, multi-storage support, intelligent notifications, and comprehensive monitoring.

---

The script will be migrated to a different language very soon, so we are now creating the structure to accommodate it. The current bash script is still active and will remain functional; it has only been moved to its own dedicated branch called old.
The installation file currently points to the old branch and allows the bash script to be installed (it warns that the script is old, which is not true at this time; confirm and proceed as normal).

We are working hard around the clock to deliver the new code, which will integrate advanced features such as AGE encryption for backups.

The original readme is available in the old baranch:

https://github.com/tis24dev/proxmox-backup/tree/old?tab=readme-ov-file

---

** Manual Bash Install (Stable)**
```bash
# Enter the /opt directory
cd /opt

# Download the repository (stable release)
wget https://github.com/tis24dev/proxmox-backup/archive/refs/tags/v0.7.4-bash.tar.gz

# Create the script directory
mkdir proxmox-backup

# Extract the script files into the newly created directory, then delete the archive
tar xzf v0.7.4-bash.tar.gz -C proxmox-backup --strip-components=1 && rm v0.7.4-bash.tar.gz

# Enter the script directory
cd proxmox-backup

# Start the installation (runs initial checks, creates symlinks, creates cron)
./install.sh

# Customize your settings
nano env/backup.env

# Run first backup
./script/proxmox-backup.sh

```


** Fast Bash Install or Update or Reinstall (Stable)**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
```

---

## 📄 License

This project is distributed under the MIT license. See the `LICENSE` file for more details.

---

## 📞 Support

- **Complete documentation**: See `doc/README.md`
- **Detailed configuration**: See `doc/CONFIGURATION.md`
- **Issues**: Open an issue on GitHub for bugs or feature requests
- **Discussions**: Use GitHub Discussions for general questions

---

## 🔄 Quick Reference

### Installation Commands
```bash
# Automatic installation (detects existing and asks) - RECOMMENDED - Stable
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"

# Automatic installation (detects existing and asks) - Development
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- dev

# Verbose mode for debugging - Stable
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -v
```

### System Commands
```bash
proxmox-backup					# Run backup
proxmox-backup --dry-run		# Test mode
proxmox-backup-security			# Security checks
proxmox-backup-permissions		# Fix permissions
proxmox-restore					# Restore data from backup
```

---

## ⭐ Stargazers

If this project is useful to you, consider giving it a ⭐!
