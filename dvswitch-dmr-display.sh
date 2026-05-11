#!/usr/bin/env bash
set -u

VERSION="0.3-test"
ROOT="/usr/share/dvswitch"
STAMP="$(date +%Y%m%d-%H%M%S)"
ORIGINAL_BACKUP_DIR="$ROOT/.dvs-dashboard-dmr-display-original"
RUN_BACKUP_DIR="$ROOT/.dvs-dashboard-dmr-display-backup-$STAMP"
LOG_DIR="/var/log/dvs-dashboard-dmr-display"
LOG_FILE="$LOG_DIR/dvs-dashboard-dmr-display-$STAMP.log"

STATUS_FILE="$ROOT/include/status.php"
CACHE_FILE="$ROOT/include/dvs-dmr-talkgroups.tsv"
INSTALLED_SCRIPT="/usr/local/sbin/dvswitch-dmr-display-cleanup"
SYSTEMD_SERVICE="/etc/systemd/system/dvs-dashboard-dmr-cache-update.service"
SYSTEMD_TIMER="/etc/systemd/system/dvs-dashboard-dmr-cache-update.timer"

log(){ mkdir -p "$LOG_DIR" 2>/dev/null || true; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die(){ log "ERROR: $*"; exit 1; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    die "Run with sudo."
  fi
}

require_file(){
  [ -f "$1" ] || die "Missing required file: $1"
}

copy_files_to(){
  dest="$1"
  mkdir -p "$dest/include" || die "Could not create backup directory: $dest/include"
  cp -a "$STATUS_FILE" "$dest/include/status.php" || die "Could not backup status.php"
  if [ -f "$CACHE_FILE" ]; then
    cp -a "$CACHE_FILE" "$dest/include/dvs-dmr-talkgroups.tsv" || die "Could not backup talkgroup cache"
  fi
}

restore_files_from(){
  src="$1"
  [ -f "$src/include/status.php" ] || die "Backup missing include/status.php"
  cp -a "$src/include/status.php" "$STATUS_FILE" || die "Could not restore status.php"

  if [ -f "$src/include/dvs-dmr-talkgroups.tsv" ]; then
    cp -a "$src/include/dvs-dmr-talkgroups.tsv" "$CACHE_FILE" || die "Could not restore talkgroup cache"
  else
    rm -f "$CACHE_FILE"
  fi
}

ensure_original_backup(){
  if [ -d "$ORIGINAL_BACKUP_DIR" ]; then
    log "Protected original backup already exists and will NOT be overwritten: $ORIGINAL_BACKUP_DIR"
    return 0
  fi

  log "Creating protected original dashboard backup: $ORIGINAL_BACKUP_DIR"
  copy_files_to "$ORIGINAL_BACKUP_DIR"

  {
    echo "DVSwitch Dashboard DMR Display Cleanup original backup"
    echo "Created: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Script version: $VERSION"
    echo "This directory is intentionally preserved and should not be overwritten by later apply runs."
  } > "$ORIGINAL_BACKUP_DIR/README.txt" || true
}

create_run_backup(){
  log "Creating per-run backup: $RUN_BACKUP_DIR"
  copy_files_to "$RUN_BACKUP_DIR"
}

create_seed_cache_if_missing(){
  if [ -f "$CACHE_FILE" ]; then
    log "Talkgroup cache already exists: $CACHE_FILE"
    return 0
  fi

  cat > "$CACHE_FILE" <<'EOF'
# DVSwitch Dashboard DMR display name cache
# Format:
# NETWORK<TAB>ID<TAB>NAME
#
# Examples:
# TGIF	31665	TGIF The Mothership
# BM	3100	USA Nationwide
# DMR+	4000	Disconnect
# FreeDMR	2350	UK Calling
# SystemX	3100	USA Nationwide
#
# Lookup is network + ID scoped. The same TG number can safely have different names on different networks.
# The dashboard reads this local file only. The installer refreshes this cache immediately and installs a weekly updater timer.
EOF
  log "Created seed talkgroup cache: $CACHE_FILE"
}

update_cache(){
  need_root
  mkdir -p "$(dirname "$CACHE_FILE")" || die "Could not create cache directory"

  tmp="$(mktemp)" || die "Could not create temporary file"

  log "Updating local DMR talkgroup cache from current internet sources"
  log "Cache destination: $CACHE_FILE"

  python3 - "$tmp" <<'PY'
import csv
import html
import re
import sys
import urllib.request
from html.parser import HTMLParser
from io import StringIO
from pathlib import Path

out_path = Path(sys.argv[1])
rows = []
seen = set()

class TextParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
    def handle_data(self, data):
        data = data.strip()
        if data:
            self.parts.append(data)

def add(network, ident, name):
    network = str(network).strip()
    ident = re.sub(r'[^0-9]', '', str(ident))
    name = html.unescape(str(name)).strip()
    name = re.sub(r'\s+', ' ', name)
    if not network or not ident or not name:
        return
    if name.lower() in {'talkgroup name', 'talkgroup', 'name'}:
        return
    key = (network, ident)
    if key in seen:
        return
    seen.add(key)
    rows.append((network, ident, name))

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'DVSwitch-Dashboard-DMR-Display/0.2'})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode('utf-8', 'replace')

def parse_csv(network, url):
    data = fetch(url)
    sample = data[:4096]
    try:
        dialect = csv.Sniffer().sniff(sample)
    except Exception:
        dialect = csv.excel
    reader = csv.reader(StringIO(data), dialect)
    for row in reader:
        if len(row) < 2:
            continue
        first = row[0].strip()
        second = row[1].strip()
        if not re.search(r'\d', first):
            continue
        add(network, first, second)

def parse_w0chp_page(network, url):
    data = fetch(url)
    parser = TextParser()
    parser.feed(data)
    tokens = parser.parts

    # W0CHP pages render as alternating "number" then "name" tokens.
    for i, token in enumerate(tokens[:-1]):
        if re.fullmatch(r'\d{1,9}', token):
            nxt = tokens[i + 1]
            if not re.fullmatch(r'[↑↓| ]+', nxt) and not nxt.lower().startswith('document version'):
                add(network, token, nxt)

sources = [
    ('TGIF', 'csv', 'https://api.tgif.network/dmr/talkgroups/csv'),
    ('BM', 'html', 'https://w0chp.radio/digital-radio-lists/brandmeister-talkgroups/'),
    ('FreeDMR', 'html', 'https://w0chp.radio/digital-radio-lists/freedmr-talkgroups/'),
    ('DMR+', 'html', 'https://w0chp.radio/digital-radio-lists/dmrplus-talkgroups/'),
    ('SystemX', 'html', 'https://w0chp.radio/digital-radio-lists/system-x-talkgroups/'),
]

errors = []
for network, kind, url in sources:
    before = len(rows)
    try:
        if kind == 'csv':
            parse_csv(network, url)
        else:
            parse_w0chp_page(network, url)
        print(f"OK: {network}: added {len(rows) - before} entries from {url}")
    except Exception as e:
        errors.append(f"WARNING: {network}: {e}")
        print(errors[-1])

with out_path.open('w', encoding='utf-8') as f:
    f.write('# DVSwitch Dashboard DMR display name cache\n')
    f.write('# Generated by dvswitch-dmr-display-cleanup.sh\n')
    f.write('# Format: NETWORK<TAB>ID<TAB>NAME\n')
    f.write('# Lookup is network + ID scoped.\n')
    for network, ident, name in sorted(rows, key=lambda x: (x[0], int(x[1]))):
        f.write(f'{network}\t{ident}\t{name}\n')

if not rows:
    raise SystemExit('No talkgroup entries were downloaded; refusing to replace cache')
PY

  [ -s "$tmp" ] || die "Generated cache is empty"
  cp -a "$tmp" "$CACHE_FILE" || die "Could not install updated cache"
  rm -f "$tmp"
  chmod 0644 "$CACHE_FILE" || true
  log "Updated talkgroup cache: $CACHE_FILE"
  log "Cache entry count: $(grep -cv '^#\|^$' "$CACHE_FILE" 2>/dev/null || echo 0)"
  log "Log file: $LOG_FILE"
}

patch_status_php(){
  python3 - "$STATUS_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
marker = "// DVS-DMR-DISPLAY-CLEANUP v0.2-test"

helper = r'''
// DVS-DMR-DISPLAY-CLEANUP v0.2-test
// Display-only helpers. No tuning, routing, startup TG, or network config is changed.
if (!function_exists('dvs_dmr_display_network_key')) {
    function dvs_dmr_display_network_key($dmrMasterHost) {
        $s = strtoupper(str_replace('_', ' ', (string)$dmrMasterHost));
        if (strpos($s, 'TGIF') !== false) { return 'TGIF'; }
        if (strpos($s, 'BRANDMEISTER') !== false || strpos($s, 'BM ') === 0 || strpos($s, 'BM-') === 0 || strpos($s, 'BM') === 0) { return 'BM'; }
        if (strpos($s, 'FREEDMR') !== false || strpos($s, 'FREE DMR') !== false) { return 'FreeDMR'; }
        if (strpos($s, 'DMR+') !== false || strpos($s, 'DMRPLUS') !== false || strpos($s, 'DMR PLUS') !== false) { return 'DMR+'; }
        if (strpos($s, 'SYSTEM X') !== false || strpos($s, 'SYSTEMX') !== false) { return 'SystemX'; }
        return 'DMR';
    }
}

if (!function_exists('dvs_dmr_display_current_tg')) {
    function dvs_dmr_display_current_tg($abinfo) {
        $tg = isset($abinfo['digital']['tg']) ? trim((string)$abinfo['digital']['tg']) : '';
        if (preg_match('/^\d+$/', $tg)) { return $tg; }

        $lastTune = isset($abinfo['last_tune']) ? trim((string)$abinfo['last_tune']) : '';
        if (preg_match('/^TG\s*(\d+)$/i', $lastTune, $m)) { return $m[1]; }
        if (preg_match('/^\d+$/', $lastTune)) { return $lastTune; }

        return '';
    }
}

if (!function_exists('dvs_dmr_display_lookup_name')) {
    function dvs_dmr_display_lookup_name($network, $id) {
        $cacheFile = dirname(__FILE__) . '/dvs-dmr-talkgroups.tsv';
        if (!is_readable($cacheFile)) { return ''; }

        $network = trim((string)$network);
        $id = trim((string)$id);
        if ($network === '' || $id === '') { return ''; }

        $lines = file($cacheFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (!is_array($lines)) { return ''; }

        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || strpos($line, '#') === 0) { continue; }
            $parts = explode("\t", $line, 3);
            if (count($parts) < 3) { continue; }
            if (strcasecmp(trim($parts[0]), $network) === 0 && trim($parts[1]) === $id) {
                return trim($parts[2]);
            }
        }
        return '';
    }
}

if (!function_exists('dvs_dmr_display_mode_label')) {
    function dvs_dmr_display_mode_label($ambeMode, $dmrMasterHost) {
        if (strtoupper((string)$ambeMode) !== 'DMR') {
            return htmlspecialchars((string)$ambeMode, ENT_QUOTES, 'UTF-8');
        }
        return htmlspecialchars(dvs_dmr_display_network_key($dmrMasterHost), ENT_QUOTES, 'UTF-8');
    }
}

if (!function_exists('dvs_dmr_display_master_label')) {
    function dvs_dmr_display_master_label($dmrMasterHost, $abinfo) {
        $network = dvs_dmr_display_network_key($dmrMasterHost);
        $tg = dvs_dmr_display_current_tg($abinfo);

        if ($network === 'DMR' || $tg === '') {
            return htmlspecialchars((string)$dmrMasterHost, ENT_QUOTES, 'UTF-8');
        }

        $name = dvs_dmr_display_lookup_name($network, $tg);
        if ($name !== '') {
            return htmlspecialchars($name, ENT_QUOTES, 'UTF-8');
        }

        return htmlspecialchars('TG ' . $tg, ENT_QUOTES, 'UTF-8');
    }
}
'''

if marker not in text:
    needle = "include_once dirname(dirname(__FILE__)).'/include/functions.php';\n"
    if needle not in text:
        raise SystemExit('Could not find functions.php include marker in status.php')
    text = text.replace(needle, needle + helper + "\n", 1)

old_mode = 'echo "<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".$abinfo[\'tlv\'][\'ambe_mode\']."</td></tr>\\n";'
new_mode = 'echo "<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".dvs_dmr_display_mode_label($abinfo[\'tlv\'][\'ambe_mode\'], $dmrMasterHost)."</td></tr>\\n";'

mode_count = text.count(old_mode)
if mode_count == 0 and new_mode not in text:
    raise SystemExit('Could not find Analog Bridge Mode output line in status.php')
text = text.replace(old_mode, new_mode)

old_master = 'echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".$dmrMasterHost."</span></td></tr>\\n";}'
new_master = 'echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".dvs_dmr_display_master_label($dmrMasterHost, $abinfo)."</span></td></tr>\\n";}'

if old_master not in text and new_master not in text:
    raise SystemExit('Could not find direct DMR Master output line in status.php')
text = text.replace(old_master, new_master, 1)

path.write_text(text)
PY
}

install_weekly_cache_timer(){
  need_root

  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    cp -a "${BASH_SOURCE[0]}" "$INSTALLED_SCRIPT" || die "Could not install helper script to $INSTALLED_SCRIPT"
    chmod 755 "$INSTALLED_SCRIPT" || die "Could not chmod $INSTALLED_SCRIPT"
    log "Installed updater/helper script: $INSTALLED_SCRIPT"
  else
    die "Could not locate running script for installation"
  fi

  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=DVSwitch Dashboard DMR talkgroup name cache update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT --update-cache
EOF

  cat > "$SYSTEMD_TIMER" <<'EOF'
[Unit]
Description=Weekly DVSwitch Dashboard DMR talkgroup name cache update

[Timer]
OnCalendar=Sun *-*-* 03:25:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload || die "systemctl daemon-reload failed"
  systemctl enable --now "$(basename "$SYSTEMD_TIMER")" || die "Could not enable weekly cache update timer"
  log "Installed and enabled weekly cache update timer: $(basename "$SYSTEMD_TIMER")"
}

remove_weekly_cache_timer(){
  need_root

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$(basename "$SYSTEMD_TIMER")" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$(basename "$SYSTEMD_SERVICE")" "$(basename "$SYSTEMD_TIMER")" >/dev/null 2>&1 || true
  else
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
  fi

  rm -f "$INSTALLED_SCRIPT"
  log "Removed weekly cache updater service/timer and installed helper script."
}

apply_patch(){
  need_root
  require_file "$STATUS_FILE"

  ensure_original_backup
  create_run_backup
  create_seed_cache_if_missing

  log "Applying DVSwitch Dashboard DMR display cleanup v$VERSION"
  log "Scope: display only; status.php only; no tuning/config/routing changes."

  update_cache
  install_weekly_cache_timer
  patch_status_php

  log "Patched status.php."
  log "Analog Bridge Info Mode displays DMR network label when ambe_mode is DMR."
  log "Direct DMR Master box displays talkgroup name from network+TG cache when available."
  log "Protected original backup: $ORIGINAL_BACKUP_DIR"
  log "Per-run backup: $RUN_BACKUP_DIR"
  log "Talkgroup cache: $CACHE_FILE"
  log "Weekly cache updater: $(basename "$SYSTEMD_TIMER")"
  log "Refresh the DVSwitch Dashboard in the browser."
  log "Log file: $LOG_FILE"
}

restore_latest(){
  need_root
  latest="$(find "$ROOT" -maxdepth 1 -type d -name '.dvs-dashboard-dmr-display-backup-*' | sort | tail -n 1)"
  [ -n "$latest" ] || die "No per-run DMR display backup directory found in $ROOT"
  restore_files_from "$latest"
  log "Restored dashboard files from latest per-run backup: $latest"
  log "Protected original backup was not changed: $ORIGINAL_BACKUP_DIR"
  log "Log file: $LOG_FILE"
}

restore_original(){
  need_root
  [ -d "$ORIGINAL_BACKUP_DIR" ] || die "Protected original backup does not exist: $ORIGINAL_BACKUP_DIR"
  restore_files_from "$ORIGINAL_BACKUP_DIR"
  log "Restored dashboard files from protected original backup: $ORIGINAL_BACKUP_DIR"
  log "This should return tracked files to their pre-DMR-display-patch state."
  log "Log file: $LOG_FILE"
}

show_status(){
  echo "DVSwitch Dashboard DMR Display Cleanup v$VERSION"
  echo
  echo "Tracked files:"
  echo "  $STATUS_FILE"
  echo "  $CACHE_FILE"
  echo "  $LOG_DIR"
  echo
  if [ -d "$ORIGINAL_BACKUP_DIR" ]; then
    echo "Protected original backup: FOUND"
    echo "  $ORIGINAL_BACKUP_DIR"
  else
    echo "Protected original backup: NOT FOUND"
  fi
  echo
  echo "Current patch markers:"
  grep -Hn 'DVS-DMR-DISPLAY-CLEANUP\|dvs_dmr_display_mode_label\|dvs_dmr_display_master_label' "$STATUS_FILE" 2>/dev/null || true
  echo
  if [ -f "$CACHE_FILE" ]; then
    echo "Talkgroup cache: FOUND"
    echo "  $CACHE_FILE"
    echo "Cache entries: $(grep -cv '^#\|^$' "$CACHE_FILE" 2>/dev/null || echo 0)"
  else
    echo "Talkgroup cache: NOT FOUND"
  fi
  echo
  if [ -f "$SYSTEMD_TIMER" ]; then
    echo "Weekly cache updater: INSTALLED"
    systemctl is-enabled "$(basename "$SYSTEMD_TIMER")" 2>/dev/null | sed 's/^/  Enabled: /' || true
    systemctl is-active "$(basename "$SYSTEMD_TIMER")" 2>/dev/null | sed 's/^/  Active: /' || true
  else
    echo "Weekly cache updater: NOT INSTALLED"
  fi
}

case "${1:-menu}" in
  apply|--apply)
    apply_patch
    ;;
  update-cache|--update-cache)
    update_cache
    ;;
  restore-latest|--restore-latest)
    restore_latest
    ;;
  restore-original|restore-factory|--restore-original|--restore-factory)
    restore_original
    ;;
  status|--status)
    show_status
    ;;
  *)
    echo "DVSwitch Dashboard DMR Display Cleanup v$VERSION"
    echo "1 = Apply DMR display cleanup, build cache, and install weekly cache updater"
    echo "2 = Restore latest per-run backup"
    echo "3 = Restore protected original files"
    echo "4 = Show DMR-display status markers"
    echo "5 = Update local talkgroup name cache from internet now"
    echo "0 = Exit"
    printf "Choose an action [0/1/2/3/4/5]: "
    read -r choice
    case "$choice" in
      1) apply_patch ;;
      2) restore_latest ;;
      3) restore_original ;;
      4) show_status ;;
      5) update_cache ;;
      0) exit 0 ;;
      *) die "Invalid choice" ;;
    esac
    ;;
esac
