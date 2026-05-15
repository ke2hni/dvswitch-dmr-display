# 📡 DVSwitch Dashboard DMR Display Cleanup

<p align="center">
  <img src="https://img.shields.io/badge/DVSwitch-DMR%20Display%20Cleanup-blueviolet?style=for-the-badge">
  <img src="https://img.shields.io/badge/Version-v0.4.11--test-brightgreen?style=for-the-badge">
  <img src="https://img.shields.io/badge/Debian%2013-Trixie-red?style=for-the-badge&logo=debian">
  <img src="https://img.shields.io/badge/ASL3-Compatible-success?style=for-the-badge">
</p>

---

## 📌 Overview

The **DVSwitch Dashboard DMR Display Cleanup** overlay modernizes and improves how the stock DVSwitch Dashboard displays DMR network and talkgroup information.

This project adds:

- live DMR network name display
- live talkgroup name resolution
- automatic internet-based talkgroup cache updates
- safe backup/restore support
- production-safe overlay patching

while preserving original DVSwitch functionality and runtime behavior.

---

## 🎯 What This Script Fixes

### Before

The stock DVSwitch dashboard typically displays:

```text
Mode        DMR
DMR Master  TGIF Network
```

### After

The dashboard dynamically displays:

```text
Mode        TGIF
DMR Master  TGIF The Mothership
```

or:

```text
Mode        BM
DMR Master  USA Nationwide
```

depending on:

- active DMR network
- active tuned talkgroup
- live talkgroup cache lookup

---

## 📥 Installation

```bash
git clone https://github.com/ke2hni/DVSwitch-DMR-Display.git
cd DVSwitch-DMR-Display
chmod +x dvswitch-dmr-display.sh
sudo ./dvswitch-dmr-display.sh
```

---

## 📋 Menu

```text
DVSwitch Dashboard DMR Display Cleanup v0.4.11-test

1 = Apply DMR display cleanup, build cache, and install weekly cache updater
2 = Restore latest per-run backup
3 = Restore protected original files
4 = Show DMR-display status markers
5 = Update local talkgroup name cache from internet now
0 = Exit
```

---

## 🎨 Features

### 📡 Live DMR Network Display

When DMR mode is active:

```text
Mode    DMR
```

is replaced with:

```text
Mode    TGIF
Mode    BM
Mode    FreeDMR
Mode    DMR+
Mode    SystemX
```

based on the currently active DMR network.

---

### 🏷️ Live Talkgroup Name Display

The DMR Master box dynamically displays:

- talkgroup names
- reflector names
- network target names

instead of generic labels like:

```text
TGIF Network
TG 31665
```

---

### 🌐 Automatic Internet-Based Cache Updates

The script automatically downloads and builds a local talkgroup cache from:

- TGIF official API
- BrandMeister lists
- FreeDMR lists
- DMR+ lists
- SystemX lists

---

### 🔄 Weekly Automatic Updates

Installed timer:

```text
dvs-dashboard-dmr-cache-update.timer
```

Default schedule:

```text
Sunday 03:25 AM
RandomizedDelaySec=30m
```

---

## 🧩 What The Script Modifies

### Dashboard Files

```text
/usr/share/dvswitch/include/status.php
```

### Local Cache File

```text
/usr/share/dvswitch/include/dvs-dmr-talkgroups.tsv
```

### Installed Helper Script

```text
/usr/local/sbin/dvswitch-dmr-display-cleanup
```

### Installed systemd Units

```text
/etc/systemd/system/dvs-dashboard-dmr-cache-update.service
/etc/systemd/system/dvs-dashboard-dmr-cache-update.timer
```

### Log Directory

```text
/var/log/dvs-dashboard-dmr-display/
```

---

## 🛡️ Safe Backup / Restore System

### Protected Original Backup

```text
/usr/share/dvswitch/.dvs-dashboard-dmr-display-original
```

### Per-Run Backups

```text
/usr/share/dvswitch/.dvs-dashboard-dmr-display-backup-YYYYMMDD-HHMMSS
```

---

## 🧠 Network-Safe Lookup Architecture

The cache uses:

```text
NETWORK + TG_NUMBER + NAME
```

Example:

```text
TGIF      31665    TGIF The Mothership
BM        3100     USA Nationwide
FreeDMR   91       World Wide
```

This prevents:

- incorrect cross-network names
- TG collisions between networks
- BM/TGIF name leakage

---

## 🧪 Confirmed Tested Networks

Successfully tested:

- TGIF
- BrandMeister

Confirmed working:

- live TG changes
- network switching
- live cache lookups
- restore logic
- automatic cache updates
- systemd timer updates

---

## 🧠 Design Philosophy

This project intentionally avoids:

- tuning changes
- routing changes
- DMR runtime modifications
- network configuration changes
- startup TG changes

This is strictly:

```text
DISPLAY CLEANUP ONLY
```

---

## 📌 Current Stable Baseline

```text
dvswitch-dmr-display-cleanup.sh
Display Cleanup Baseline: v0.3-test
```

---

## 🚀 Long-Term Goals

Future expansion may include:

- YSF name lookups
- P25 TG name lookups
- NXDN name lookups
- STFU target names
- D-Star reflector names

using the same:

```text
MODE/NETWORK + TARGET_ID + FRIENDLY_NAME
```

architecture.

---

## 📜 License

Use at your own risk.

Always test on a non-production node first.

---

<p align="center">
  📡 Built to modernize DVSwitch Dashboard display readability safely without breaking upstream behavior
</p>
<img width="1600" height="900" alt="Screenshot 2026-05-10 225632" src="https://github.com/user-attachments/assets/dbd43c79-2572-4aca-9856-50ea3b37aa80" />
