#!/usr/bin/env bash
set -u

VERSION="v0.4.16-test"
APP_NAME="DVSwitch Dashboard DMR Display Cleanup"
DVS_ROOT="/usr/share/dvswitch"
STATUS_FILE="${DVS_ROOT}/include/status.php"
TG_CACHE_FILE="${DVS_ROOT}/include/dvs-dmr-talkgroups.tsv"
STATE_DIR="/var/lib/mmdvm/cache"
STATE_FILE="${STATE_DIR}/dmr_last_state.json"
ORIG_BACKUP_DIR="${DVS_ROOT}/.dvs-dashboard-dmr-display-cleanup-original"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_BACKUP_DIR="${DVS_ROOT}/.dvs-dashboard-dmr-display-cleanup-backup-${RUN_ID}"
LOG_FILE="/root/dvs-dashboard-dmr-display-cleanup-${RUN_ID}.log"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
CACHE_SERVICE_FILE="/etc/systemd/system/dvs-dashboard-dmr-cache-update.service"
CACHE_TIMER_FILE="/etc/systemd/system/dvs-dashboard-dmr-cache-update.timer"
RESTORE_HELPER_FILE="/usr/local/sbin/dvs-dashboard-dmr-target-restore"
RESTORE_SERVICE_FILE="/etc/systemd/system/dvs-dashboard-dmr-target-restore.service"
RESTORE_TIMER_FILE="/etc/systemd/system/dvs-dashboard-dmr-target-restore.timer"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die(){ log "ERROR: $*"; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "Run with sudo/root."; }

backup_files(){
  [ -f "$STATUS_FILE" ] || die "Missing dashboard status file: $STATUS_FILE"

  if [ ! -d "$ORIG_BACKUP_DIR" ]; then
    log "Creating protected original dashboard backup: $ORIG_BACKUP_DIR"
    mkdir -p "$ORIG_BACKUP_DIR" || die "Could not create protected original backup directory"
    cp -a "$STATUS_FILE" "$ORIG_BACKUP_DIR/status.php" || die "Could not backup original status.php"
    [ -f "$TG_CACHE_FILE" ] && cp -a "$TG_CACHE_FILE" "$ORIG_BACKUP_DIR/dvs-dmr-talkgroups.tsv"
  elif [ ! -f "$ORIG_BACKUP_DIR/status.php" ]; then
    log "WARNING: Protected original backup directory exists but status.php is missing. Repairing missing original backup file only."
    cp -a "$STATUS_FILE" "$ORIG_BACKUP_DIR/status.php" || die "Could not repair protected original status.php backup"
    [ -f "$TG_CACHE_FILE" ] && [ ! -f "$ORIG_BACKUP_DIR/dvs-dmr-talkgroups.tsv" ] && cp -a "$TG_CACHE_FILE" "$ORIG_BACKUP_DIR/dvs-dmr-talkgroups.tsv"
  else
    log "Protected original backup already exists and will NOT be overwritten: $ORIG_BACKUP_DIR"
  fi

  log "Creating per-run backup: $RUN_BACKUP_DIR"
  mkdir -p "$RUN_BACKUP_DIR" || die "Could not create per-run backup directory"
  cp -a "$STATUS_FILE" "$RUN_BACKUP_DIR/status.php" || die "Could not backup status.php"
  [ -f "$TG_CACHE_FILE" ] && cp -a "$TG_CACHE_FILE" "$RUN_BACKUP_DIR/dvs-dmr-talkgroups.tsv"
}

restore_from_dir(){
  src="$1"
  [ -f "$src/status.php" ] || die "Backup missing status.php: $src"
  cp -a "$src/status.php" "$STATUS_FILE" || die "Could not restore status.php"
  if [ -f "$src/dvs-dmr-talkgroups.tsv" ]; then
    cp -a "$src/dvs-dmr-talkgroups.tsv" "$TG_CACHE_FILE" || die "Could not restore talkgroup cache"
  fi
}

validate_or_restore(){
  if php -l "$STATUS_FILE" >/tmp/dvs_dmr_php_lint_status.out 2>&1; then
    log "PHP syntax check passed for status.php"
    return 0
  fi

  cat /tmp/dvs_dmr_php_lint_status.out | tee -a "$LOG_FILE"
  log "PHP syntax check failed. Auto-restoring per-run backup: $RUN_BACKUP_DIR"
  restore_from_dir "$RUN_BACKUP_DIR"
  php -l "$STATUS_FILE" >/tmp/dvs_dmr_php_lint_status_restore.out 2>&1 || {
    cat /tmp/dvs_dmr_php_lint_status_restore.out | tee -a "$LOG_FILE"
    die "Restore completed but PHP syntax is still bad. Manual inspection required."
  }
  die "Patch rejected and status.php restored cleanly."
}


write_seed_cache(){
  mkdir -p "$(dirname "$TG_CACHE_FILE")" || die "Could not create TG cache directory"
  cat > "$TG_CACHE_FILE" <<'EOF_SEED'
# DVSwitch Dashboard DMR talkgroup cache
# Format: NETWORK<TAB>TG<TAB>NAME
# This starter cache is used if online updates are unavailable.
BM	1	Local
BM	2	Cluster
BM	8	Regional
BM	9	Local
BM	91	World-wide
BM	92	Europe
BM	93	North America
BM	94	Asia, Middle East
BM	95	Australia, New Zealand
BM	98	Radio Test
BM	310	TAC 310
BM	311	TAC 311
BM	312	TAC 312
BM	313	TAC 313
BM	314	TAC 314
BM	315	TAC 315
BM	316	TAC 316
BM	317	TAC 317
BM	318	TAC 318
BM	319	TAC 319
# STFU is BrandMeister-backed; display lookup intentionally uses BM rows.
TGIF	31665	Parrot
EOF_SEED
  chmod 0644 "$TG_CACHE_FILE" || true
  log "Created starter DMR talkgroup cache: $TG_CACHE_FILE"
}

update_cache(){
  need_root
  mkdir -p "$(dirname "$TG_CACHE_FILE")" || die "Could not create TG cache directory"
  tmp="$(mktemp /tmp/dvs-dmr-talkgroups.XXXXXX)" || die "Could not create temporary cache file"

  log "Updating DMR talkgroup name cache: $TG_CACHE_FILE"

  python3 - "$tmp" <<'PY_CACHE'
import csv
import html
import re
import sys
import urllib.request
from pathlib import Path

out = Path(sys.argv[1])
rows = []
seen = set()

def add(network, tg, name):
    network = str(network).strip()
    tg = re.sub(r'\D+', '', str(tg).strip())
    name = html.unescape(str(name).strip())
    name = re.sub(r'\s+', ' ', name)
    if not network or not tg or not name:
        return
    key = (network.upper(), tg)
    if key in seen:
        return
    seen.add(key)
    rows.append((network, tg, name))

def fetch(url, timeout=20):
    req = urllib.request.Request(url, headers={'User-Agent': 'dvs-dashboard-dmr-display-cache/0.4.14'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')

for tg, name in [
    ('1','Local'), ('2','Cluster'), ('8','Regional'), ('9','Local'),
    ('91','World-wide'), ('92','Europe'), ('93','North America'),
    ('94','Asia, Middle East'), ('95','Australia, New Zealand'), ('98','Radio Test'),
    ('310','TAC 310'), ('311','TAC 311'), ('312','TAC 312'), ('313','TAC 313'),
    ('314','TAC 314'), ('315','TAC 315'), ('316','TAC 316'), ('317','TAC 317'),
    ('318','TAC 318'), ('319','TAC 319')
]:
    add('BM', tg, name)

try:
    data = fetch('https://api.tgif.network/dmr/talkgroups/csv')
    for rec in csv.reader(data.splitlines()):
        if len(rec) >= 2 and re.fullmatch(r'\d+', rec[0].strip()):
            add('TGIF', rec[0], rec[1])
except Exception as e:
    print(f'WARNING: TGIF cache source failed: {e}', file=sys.stderr)

try:
    data = fetch('https://www.pistar.uk/dmr_bm_talkgroups.php')
    text = re.sub(r'<[^>]+>', ' ', data)
    text = html.unescape(re.sub(r'\s+', ' ', text))
    matches = re.finditer(r'\bTG\s+(\d{1,8})\s+(.+?)(?=\s+TG\s+\d{1,8}\s+|\s+There are\b|\s+listen live\b|$)', text, re.I)
    for m in matches:
        name = re.sub(r'\s*listen live\s*$', '', m.group(2), flags=re.I).strip()
        if name and not name.lower().startswith('number'):
            add('BM', m.group(1), name)
except Exception as e:
    print(f'WARNING: BrandMeister cache source failed: {e}', file=sys.stderr)

rows.sort(key=lambda r: (r[0].upper(), int(r[1]) if r[1].isdigit() else 999999999, r[2].lower()))
with out.open('w', encoding='utf-8', newline='') as f:
    f.write('# DVSwitch Dashboard DMR talkgroup cache\n')
    f.write('# Format: NETWORK<TAB>TG<TAB>NAME\n')
    f.write('# Generated by dvswitch-dmr-display.sh update-cache\n')
    for network, tg, name in rows:
        f.write(f'{network}\t{tg}\t{name}\n')
print(len(rows))
PY_CACHE
  rc=$?

  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    log "WARNING: Online DMR cache update failed."
    rm -f "$tmp"
    if [ -s "$TG_CACHE_FILE" ]; then
      log "Keeping existing DMR talkgroup cache: $TG_CACHE_FILE"
    else
      write_seed_cache
    fi
    return 0
  fi

  new_count="$(grep -vc '^#' "$tmp" 2>/dev/null || echo 0)"
  old_count="$(grep -vc '^#' "$TG_CACHE_FILE" 2>/dev/null || echo 0)"
  if [ -s "$TG_CACHE_FILE" ] && [ "${new_count:-0}" -lt 50 ] && [ "${old_count:-0}" -gt "${new_count:-0}" ]; then
    log "WARNING: Online cache update only produced $new_count entries; keeping existing $old_count-entry cache."
    rm -f "$tmp"
    return 0
  fi

  install -m 0644 "$tmp" "$TG_CACHE_FILE" || die "Could not install updated TG cache"
  rm -f "$tmp"
  log "Updated DMR talkgroup cache: $TG_CACHE_FILE"
  log "Cache line count: $(grep -vc '^#' "$TG_CACHE_FILE" 2>/dev/null || echo 0)"
}

ensure_cache(){
  if [ -s "$TG_CACHE_FILE" ]; then
    log "DMR talkgroup cache exists: $TG_CACHE_FILE"
  else
    log "DMR talkgroup cache missing; creating it now."
    update_cache || write_seed_cache
  fi
}

install_cache_timer(){
  need_root
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not found; skipping automatic cache timer install."
    return 0
  fi

  cat > "$CACHE_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Update DVSwitch Dashboard DMR talkgroup name cache
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF_PATH update-cache
EOF_SERVICE

  cat > "$CACHE_TIMER_FILE" <<'EOF_TIMER'
[Unit]
Description=Weekly DVSwitch Dashboard DMR talkgroup name cache update

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF_TIMER

  chmod 0644 "$CACHE_SERVICE_FILE" "$CACHE_TIMER_FILE" || true
  systemctl daemon-reload || die "systemctl daemon-reload failed"
  systemctl enable --now "$(basename "$CACHE_TIMER_FILE")" >/dev/null 2>&1 || die "Could not enable cache update timer"
  log "Installed/enabled automatic weekly DMR cache update timer: $CACHE_TIMER_FILE"
}

install_target_restore_timer(){
  need_root
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not found; skipping automatic DMR target restore timer install."
    return 0
  fi

  cat > "$RESTORE_HELPER_FILE" <<'EOF_RESTORE'
#!/usr/bin/env python3
import glob, json, os, re, subprocess, sys, time
STATE_FILE = '/var/lib/mmdvm/cache/dmr_last_state.json'
DVS_TUNE = '/opt/MMDVM_Bridge/dvswitch.sh'

def read_json(path):
    try:
        with open(path, 'r', encoding='utf-8') as f: return json.load(f)
    except Exception: return {}

def newest_abinfo():
    paths = glob.glob('/tmp/ABInfo*.json')
    if not paths: return {}
    paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return read_json(paths[0])

def get_mode(ab): return str(ab.get('tlv', {}).get('ambe_mode', '')).strip().upper()

def get_tg(ab):
    tg = str(ab.get('digital', {}).get('tg', '')).strip()
    if re.fullmatch(r'\d+', tg): return tg
    last = str(ab.get('last_tune', '')).strip()
    m = re.fullmatch(r'TG\s*(\d+)', last, re.I)
    if m: return m.group(1)
    if re.fullmatch(r'\d+', last): return last
    return ''

def choose_saved(state):
    tg = str(state.get('tg', '')).strip()
    if re.fullmatch(r'\d+', tg) and tg not in ('0', '9'): return tg
    return ''

def main():
    saved_tg = choose_saved(read_json(STATE_FILE))
    if not saved_tg: return 0
    for _ in range(6):
        ab = newest_abinfo(); mode = get_mode(ab); live_tg = get_tg(ab)
        if mode in ('DMR', 'STFU'):
            if live_tg in ('', '0', '9'):
                subprocess.run([DVS_TUNE, 'tune', saved_tg], check=False)
            return 0
        time.sleep(10)
    return 0
if __name__ == '__main__': sys.exit(main())
EOF_RESTORE
  chmod 0755 "$RESTORE_HELPER_FILE" || die "Could not chmod $RESTORE_HELPER_FILE"

  cat > "$RESTORE_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Restore last valid DVSwitch DMR talkgroup after startup/fallback TG
After=network-online.target analog_bridge.service mmdvm_bridge.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RESTORE_HELPER_FILE
EOF_SERVICE

  cat > "$RESTORE_TIMER_FILE" <<'EOF_TIMER'
[Unit]
Description=Run DVSwitch DMR last-talkgroup restore after boot and periodically

[Timer]
OnBootSec=45s
OnUnitActiveSec=2min
AccuracySec=15s
Persistent=false

[Install]
WantedBy=timers.target
EOF_TIMER

  chmod 0644 "$RESTORE_SERVICE_FILE" "$RESTORE_TIMER_FILE" || true
  systemctl daemon-reload || die "systemctl daemon-reload failed"
  systemctl enable --now "$(basename "$RESTORE_TIMER_FILE")" >/dev/null 2>&1 || die "Could not enable DMR target restore timer"
  log "Installed/enabled automatic DMR last-target restore timer: $RESTORE_TIMER_FILE"
}

remove_target_restore_timer(){
  need_root
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$(basename "$RESTORE_TIMER_FILE")" >/dev/null 2>&1 || true
    rm -f "$RESTORE_SERVICE_FILE" "$RESTORE_TIMER_FILE" "$RESTORE_HELPER_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "Removed automatic DMR target restore timer/service/helper if present."
  fi
}

remove_cache_timer(){
  need_root
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$(basename "$CACHE_TIMER_FILE")" >/dev/null 2>&1 || true
    rm -f "$CACHE_SERVICE_FILE" "$CACHE_TIMER_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "Removed automatic DMR cache update timer/service if present."
  fi
}

patch_status_php(){
  log "Applying ${APP_NAME} ${VERSION}"
  log "Scope: DMR display only. Hooks required visible Mode / DMR Master rows and protects DMR state from non-DMR modes."

  mkdir -p "$STATE_DIR" || die "Could not create state directory: $STATE_DIR"
  chown www-data:www-data "$STATE_DIR" 2>/dev/null || true
  chmod 775 "$STATE_DIR" 2>/dev/null || true

  python3 - "$STATUS_FILE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

HELPER_START = "// DVS-DMR-DISPLAY-CLEANUP"
NEW_MARKER = "// DVS-DMR-DISPLAY-CLEANUP v0.4.16-test"

helper = r'''
// DVS-DMR-DISPLAY-CLEANUP v0.4.16-test
// Display-only helpers. No tuning, routing, startup TG, or network config is changed.
// DMR state updates ONLY while ABInfo reports ambe_mode=DMR.
// Non-DMR modes keep showing the last valid DMR network/TG/name. TG 0 reconnect transients are ignored.
if (!function_exists('dvs_dmr_display_state_file')) {
    function dvs_dmr_display_state_file() {
        return '/var/lib/mmdvm/cache/dmr_last_state.json';
    }
}

if (!function_exists('dvs_dmr_display_network_key')) {
    function dvs_dmr_display_network_key($dmrMasterHost, $abinfo = array()) {
        $mode = '';
        if (isset($abinfo['tlv']['ambe_mode'])) {
            $mode = strtoupper(trim((string)$abinfo['tlv']['ambe_mode']));
        }

        $s = strtoupper(str_replace('_', ' ', (string)$dmrMasterHost));

        // STFU rides BrandMeister, so use the BM talkgroup-name cache.
        if ($mode === 'STFU' || strpos($s, 'STFU') !== false) { return 'BM'; }

        if (strpos($s, 'TGIF') !== false) { return 'TGIF'; }
        if (strpos($s, 'BRANDMEISTER') !== false || strpos($s, 'BM ') === 0 || strpos($s, 'BM-') === 0 || strpos($s, 'BM') === 0) { return 'BM'; }
        if (strpos($s, 'FREEDMR') !== false || strpos($s, 'FREE DMR') !== false) { return 'FreeDMR'; }
        if (strpos($s, 'DMR+') !== false || strpos($s, 'DMRPLUS') !== false || strpos($s, 'DMR PLUS') !== false) { return 'DMR+'; }
        if (strpos($s, 'SYSTEM X') !== false || strpos($s, 'SYSTEMX') !== false) { return 'SystemX'; }
        return 'DMR';
    }
}

if (!function_exists('dvs_dmr_display_is_live_dmr')) {
    function dvs_dmr_display_is_live_dmr($abinfo) {
        $mode = '';
        if (isset($abinfo['tlv']['ambe_mode'])) {
            $mode = strtoupper(trim((string)$abinfo['tlv']['ambe_mode']));
        }
        // Treat STFU as DMR-family for display/cache lookup because STFU is BM-backed.
        return ($mode === 'DMR' || $mode === 'STFU');
    }
}

if (!function_exists('dvs_dmr_display_extract_live_tg')) {
    function dvs_dmr_display_extract_live_tg($abinfo) {
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

if (!function_exists('dvs_dmr_display_read_state')) {
    function dvs_dmr_display_read_state() {
        $file = dvs_dmr_display_state_file();
        if (!is_readable($file)) { return array(); }
        $raw = file_get_contents($file);
        if ($raw === false || trim($raw) === '') { return array(); }
        $data = json_decode($raw, true);
        if (!is_array($data)) { return array(); }
        return $data;
    }
}

if (!function_exists('dvs_dmr_display_write_state')) {
    function dvs_dmr_display_write_state($state) {
        $file = dvs_dmr_display_state_file();
        $dir = dirname($file);
        if (!is_dir($dir)) { @mkdir($dir, 0775, true); }
        if (!is_dir($dir) || !is_writable($dir)) { return false; }
        $payload = json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        if ($payload === false) { return false; }
        $tmp = $file . '.tmp';
        if (@file_put_contents($tmp, $payload . "\n", LOCK_EX) === false) { return false; }
        @chmod($tmp, 0664);
        return @rename($tmp, $file);
    }
}

if (!function_exists('dvs_dmr_display_network_state')) {
    function dvs_dmr_display_network_state($stored, $network) {
        if (!is_array($stored)) { return array(); }
        if (isset($stored['networks']) && is_array($stored['networks']) && isset($stored['networks'][$network]) && is_array($stored['networks'][$network])) {
            return $stored['networks'][$network];
        }
        if (isset($stored['network']) && strcasecmp((string)$stored['network'], (string)$network) === 0) {
            return $stored;
        }
        return array();
    }
}

if (!function_exists('dvs_dmr_display_saved_tg_for_network')) {
    function dvs_dmr_display_saved_tg_for_network($stored, $network) {
        $state = dvs_dmr_display_network_state($stored, $network);
        $tg = isset($state['tg']) ? trim((string)$state['tg']) : '';
        if ($tg === '' || $tg === '0') { return ''; }
        return $tg;
    }
}

if (!function_exists('dvs_dmr_display_update_network_state')) {
    function dvs_dmr_display_update_network_state($stored, $network, $tg, $name, $master) {
        if (!is_array($stored)) { $stored = array(); }
        if (!isset($stored['networks']) || !is_array($stored['networks'])) { $stored['networks'] = array(); }
        $entry = array('network' => $network, 'tg' => $tg, 'name' => $name, 'master' => (string)$master, 'updated' => date('c'));
        $stored['networks'][$network] = $entry;
        foreach ($entry as $k => $v) { $stored[$k] = $v; }
        dvs_dmr_display_write_state($stored);
        return $entry;
    }
}

if (!function_exists('dvs_dmr_display_current_state')) {
    function dvs_dmr_display_current_state($dmrMasterHost, $abinfo) {
        $stored = dvs_dmr_display_read_state();
        if (!dvs_dmr_display_is_live_dmr($abinfo)) { return $stored; }
        $network = dvs_dmr_display_network_key($dmrMasterHost, $abinfo);
        $tg = dvs_dmr_display_extract_live_tg($abinfo);
        if ($network === 'DMR') { return $stored; }
        // Ignore transient TG 0 and stock TG 9 fallback when a real saved TG exists for this network.
        if ($tg === '' || $tg === '0' || $tg === '9') {
            $saved = dvs_dmr_display_network_state($stored, $network);
            if (!empty($saved)) { return $saved; }
            return $stored;
        }
        $name = dvs_dmr_display_lookup_name($network, $tg);
        return dvs_dmr_display_update_network_state($stored, $network, $tg, $name, $dmrMasterHost);
    }
}

if (!function_exists('dvs_dmr_display_current_tg')) {
    function dvs_dmr_display_current_tg($abinfo, $dmrMasterHost = '') {
        $stored = dvs_dmr_display_read_state();
        $network = $dmrMasterHost !== '' ? dvs_dmr_display_network_key($dmrMasterHost, $abinfo) : (isset($stored['network']) ? (string)$stored['network'] : '');
        if (!dvs_dmr_display_is_live_dmr($abinfo)) {
            $saved = $network !== '' ? dvs_dmr_display_saved_tg_for_network($stored, $network) : '';
            if ($saved !== '') { return $saved; }
            return isset($stored['tg']) ? trim((string)$stored['tg']) : '';
        }
        $tg = dvs_dmr_display_extract_live_tg($abinfo);
        if ($tg === '' || $tg === '0' || $tg === '9') {
            $saved = $network !== '' ? dvs_dmr_display_saved_tg_for_network($stored, $network) : '';
            if ($saved !== '') { return $saved; }
            return isset($stored['tg']) ? trim((string)$stored['tg']) : '';
        }
        return $tg;
    }
}

if (!function_exists('dvs_dmr_display_mode_label')) {
    function dvs_dmr_display_mode_label($ambeMode, $dmrMasterHost, $abinfo = array()) {
        $mode = strtoupper((string)$ambeMode);
        if ($mode === 'STFU') {
            return htmlspecialchars('STFU/BM', ENT_QUOTES, 'UTF-8');
        }
        if ($mode !== 'DMR') {
            return htmlspecialchars((string)$ambeMode, ENT_QUOTES, 'UTF-8');
        }
        return htmlspecialchars(dvs_dmr_display_network_key($dmrMasterHost, $abinfo), ENT_QUOTES, 'UTF-8');
    }
}

if (!function_exists('dvs_dmr_display_master_label')) {
    function dvs_dmr_display_master_label($dmrMasterHost, $abinfo) {
        $state = dvs_dmr_display_current_state($dmrMasterHost, $abinfo);
        $network = isset($state['network']) ? trim((string)$state['network']) : '';
        $tg = isset($state['tg']) ? trim((string)$state['tg']) : '';
        $name = isset($state['name']) ? trim((string)$state['name']) : '';

        if ($network === '' || $tg === '') {
            return htmlspecialchars((string)$dmrMasterHost, ENT_QUOTES, 'UTF-8');
        }
        if ($name !== '') {
            return htmlspecialchars($name, ENT_QUOTES, 'UTF-8');
        }
        return htmlspecialchars('TG ' . $tg, ENT_QUOTES, 'UTF-8');
    }
}
'''.strip() + "\n"

# Replace any existing helper block that sits before the Status span.
helper_pattern = re.compile(
    r"// DVS-DMR-DISPLAY-CLEANUP v[0-9.]+-test\s*"
    r"// Display-only helpers\. No tuning, routing, startup TG, or network config is changed\.\s*"
    r".*?(?=\?>\s*\n<span style=\"font-weight: bold;font-size:14px;\">Status</span>)",
    re.S,
)
text, helper_replaced = helper_pattern.subn(lambda m: helper + "\n", text, count=1)

if helper_replaced:
    print("Replaced existing DMR helper block with v0.4.15")
elif NEW_MARKER not in text:
    needle = "include_once dirname(dirname(__FILE__)).'/include/functions.php';\n"
    if needle in text:
        text = text.replace(needle, needle + helper + "\n", 1)
        print("Inserted DMR helper block after functions.php include")
    else:
        status_span = '<span style="font-weight: bold;font-size:14px;">Status</span>'
        idx = text.find(status_span)
        if idx == -1:
            raise SystemExit('Could not find functions.php include marker or Status span in status.php')
        php_close = text.rfind('?>', 0, idx)
        if php_close == -1:
            raise SystemExit('Could not find PHP close before Status span')
        text = text[:php_close] + helper + "\n" + text[php_close:]
        print("Inserted DMR helper block before Status span")
else:
    print("DMR helper block already present")

# Patch visible Mode row. This is the exact hook v0.1/v0.2/v0.3 used, with an additional fallback.
old_mode = 'echo "<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".$abinfo[\'tlv\'][\'ambe_mode\']."</td></tr>\\n";'
new_mode = 'echo "<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".dvs_dmr_display_mode_label($abinfo[\'tlv\'][\'ambe_mode\'], $dmrMasterHost)."</td></tr>\\n";'
if old_mode in text:
    text = text.replace(old_mode, new_mode, 1)
    print("Patched visible Mode row using exact v0.3 hook")
elif new_mode in text:
    print("Visible Mode row already patched")
else:
    mode_pattern = re.compile(r'echo\s+"<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">"\s*\.\s*\$abinfo\[\'tlv\'\]\[\'ambe_mode\'\]\s*\.\s*"</td></tr>\\n";')
    text, n = mode_pattern.subn(new_mode, text, count=1)
    if n:
        print("Patched visible Mode row using fallback hook")
    else:
        raise SystemExit('Could not find visible Mode output line in status.php')

# Patch visible Tx TG rows so non-DMR modes show last valid DMR TG instead of wrong-mode target.
# v0.4.15 never uses a broad helper-exists shortcut; it patches any remaining raw Tx TG output lines.
new_tx_expr = 'htmlspecialchars(dvs_dmr_display_current_tg($abinfo, $dmrMasterHost), ENT_QUOTES, \'UTF-8\')'
tx_pattern = re.compile(
    r'echo\s+"<tr><th(?:\s+width=50%)?>Tx TG</th><td style=\\"background:\s*#f9f9f9;font-weight:\s*bold;color:#[0-9A-Fa-f]{6};\\">"\s*'
    r'\.\s*\$abinfo\[\'digital\'\]\[\'tg\'\]\s*\.\s*"</td></tr>\\n";'
)
def tx_repl(match):
    line = match.group(0)
    return re.sub(
        r'\$abinfo\[\'digital\'\]\[\'tg\'\]',
        new_tx_expr,
        line,
        count=1
    )
text, n = tx_pattern.subn(tx_repl, text, count=2)
if n:
    print(f"Patched visible Tx TG row using flexible default-compatible hook ({n} occurrence(s))")
else:
    # Conservative fallback for exact known formats.
    known_tx_lines = [
        'echo "<tr><th>Tx TG</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".$abinfo[\'digital\'][\'tg\']."</td></tr>\\n";',
        'echo "<tr><th width=50%>Tx TG</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#ef7215;\\">".$abinfo[\'digital\'][\'tg\']."</td></tr>\\n";',
    ]
    patched = 0
    for old_tx in known_tx_lines:
        if old_tx in text:
            text = text.replace(old_tx, old_tx.replace("$abinfo['digital']['tg']", new_tx_expr), 1)
            patched += 1
    if patched:
        print(f"Patched visible Tx TG row using known-format fallback ({patched} occurrence(s))")
    elif re.search(r'Tx TG</th><td[^\n]+dvs_dmr_display_current_tg\(\$abinfo(?:,\s*\$dmrMasterHost)?\)', text):
        print("Visible Tx TG row already patched")
    else:
        raise SystemExit('Could not find visible Tx TG output line in status.php')

# Patch direct DMR Master output. Preserve the closing brace outside the replacement.
old_master = 'echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".$dmrMasterHost."</span></td></tr>\\n";}'
new_master = 'echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".dvs_dmr_display_master_label($dmrMasterHost, $abinfo)."</span></td></tr>\\n";}'
if old_master in text:
    text = text.replace(old_master, new_master, 1)
    print("Patched visible DMR Master row using exact v0.3 hook")
elif new_master in text:
    print("Visible DMR Master row already patched")
else:
    master_pattern = re.compile(r'echo\s+"<tr><td\s+style=\\"background: #ffffed;\\"\s+colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">"\s*\.\s*\$dmrMasterHost\s*\.\s*"</span></td></tr>\\n";')
    repl = 'echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".dvs_dmr_display_master_label($dmrMasterHost, $abinfo)."</span></td></tr>\\n";'
    text, n = master_pattern.subn(repl, text, count=1)
    if n:
        print("Patched visible DMR Master row using fallback hook")
    else:
        raise SystemExit('Could not find visible DMR Master output line in status.php')

path.write_text(text)
PY
  rc=$?
  [ "$rc" -eq 0 ] || die "Could not patch status.php cleanly"
  validate_or_restore

  log "Patched helper block and required visible rows."
  log "Expected dashboard result: Mode shows DMR network label; DMR Master/Tx TG preserve the last valid DMR TG, ignore TG 0/stock TG 9 fallback, and restore last DMR TG after reboot."
  log "DMR state file: $STATE_FILE"
}

restore_latest_backup(){
  need_root
  latest="$(find "$DVS_ROOT" -maxdepth 1 -type d -name '.dvs-dashboard-dmr-display-cleanup-backup-*' | sort | tail -1)"
  [ -n "$latest" ] || die "No per-run backup found"
  log "Restoring latest per-run backup: $latest"
  restore_from_dir "$latest"
  validate_or_restore
  log "Restore latest per-run backup completed"
}

restore_original(){
  need_root
  [ -f "$ORIG_BACKUP_DIR/status.php" ] || die "Protected original backup missing status.php: $ORIG_BACKUP_DIR"
  log "Restoring protected original dashboard file backup: $ORIG_BACKUP_DIR"
  restore_from_dir "$ORIG_BACKUP_DIR"
  remove_cache_timer
  remove_target_restore_timer
  validate_or_restore
  log "Restore protected original files completed"
}

show_status(){
  echo
  echo "${APP_NAME} ${VERSION} status"
  echo "Dashboard root: $DVS_ROOT"
  echo "Status file:    $STATUS_FILE"
  echo "TG cache file:  $TG_CACHE_FILE"
  if [ -f "$TG_CACHE_FILE" ]; then echo "TG cache lines: $(grep -vc '^#' "$TG_CACHE_FILE" 2>/dev/null || echo 0)"; else echo "TG cache lines: (cache file missing)"; fi
  echo "State file:     $STATE_FILE"
  echo "Restore helper: $RESTORE_HELPER_FILE"
  echo
  echo "Markers / visible hooks in status.php:"
  grep -n "DVS-DMR-DISPLAY-CLEANUP\|dvs_dmr_display_mode_label\|dvs_dmr_display_current_tg\|dvs_dmr_display_master_label" "$STATUS_FILE" 2>/dev/null || true
  echo
  echo "Current DMR state file:"
  if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo "(not created yet)"; fi
  echo
  echo "Protected original backup:"
  if [ -d "$ORIG_BACKUP_DIR" ]; then echo "$ORIG_BACKUP_DIR"; else echo "(not created yet)"; fi
  echo
  echo "Latest per-run backup:"
  find "$DVS_ROOT" -maxdepth 1 -type d -name '.dvs-dashboard-dmr-display-cleanup-backup-*' | sort | tail -1
}

apply_cleanup(){
  need_root
  backup_files
  update_cache
  install_cache_timer
  install_target_restore_timer
  patch_status_php
  log "Protected original backup: $ORIG_BACKUP_DIR"
  log "Per-run backup: $RUN_BACKUP_DIR"
  log "Refresh the DVSwitch Dashboard in the browser."
  log "Log file: $LOG_FILE"
}

main_menu(){
  echo "${APP_NAME} ${VERSION}"
  echo "1 = Apply DMR display cleanup fix"
  echo "2 = Restore latest per-run backup"
  echo "3 = Restore protected original files"
  echo "4 = Show DMR cleanup status markers"
  echo "5 = Update DMR talkgroup name cache"
  echo "0 = Exit"
  printf "Choose an action [0/1/2/3/4/5]: "
  read -r choice
  case "$choice" in
    1) apply_cleanup ;;
    2) restore_latest_backup ;;
    3) restore_original ;;
    4) show_status | tee -a "$LOG_FILE"; log "Log file: $LOG_FILE" ;;
    5) update_cache ;;
    0) exit 0 ;;
    *) die "Invalid choice" ;;
  esac
}

case "${1:-menu}" in
  apply) apply_cleanup ;;
  restore-latest) restore_latest_backup ;;
  restore-original|restore-factory) restore_original ;;
  status) show_status | tee -a "$LOG_FILE"; log "Log file: $LOG_FILE" ;;
  update-cache|--update-cache) update_cache ;;
  install-cache-timer) install_cache_timer ;;
  remove-cache-timer) remove_cache_timer ;;
  menu|*) main_menu ;;
esac
