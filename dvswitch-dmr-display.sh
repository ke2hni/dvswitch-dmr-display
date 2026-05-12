#!/usr/bin/env bash
set -u

VERSION="v0.4.10-test"
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
NEW_MARKER = "// DVS-DMR-DISPLAY-CLEANUP v0.4.10-test"

helper = r'''
// DVS-DMR-DISPLAY-CLEANUP v0.4.10-test
// Display-only helpers. No tuning, routing, startup TG, or network config is changed.
// DMR state updates ONLY while ABInfo reports ambe_mode=DMR.
// Non-DMR modes keep showing the last valid DMR network/TG/name.
if (!function_exists('dvs_dmr_display_state_file')) {
    function dvs_dmr_display_state_file() {
        return '/var/lib/mmdvm/cache/dmr_last_state.json';
    }
}

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

if (!function_exists('dvs_dmr_display_is_live_dmr')) {
    function dvs_dmr_display_is_live_dmr($abinfo) {
        $mode = '';
        if (isset($abinfo['tlv']['ambe_mode'])) {
            $mode = trim((string)$abinfo['tlv']['ambe_mode']);
        }
        return strtoupper($mode) === 'DMR';
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

if (!function_exists('dvs_dmr_display_current_state')) {
    function dvs_dmr_display_current_state($dmrMasterHost, $abinfo) {
        $stored = dvs_dmr_display_read_state();

        if (!dvs_dmr_display_is_live_dmr($abinfo)) {
            return $stored;
        }

        $network = dvs_dmr_display_network_key($dmrMasterHost);
        $tg = dvs_dmr_display_extract_live_tg($abinfo);

        if ($network === 'DMR' || $tg === '') {
            return $stored;
        }

        $name = dvs_dmr_display_lookup_name($network, $tg);
        $state = array(
            'network' => $network,
            'tg' => $tg,
            'name' => $name,
            'master' => (string)$dmrMasterHost,
            'updated' => date('c')
        );
        dvs_dmr_display_write_state($state);
        return $state;
    }
}

if (!function_exists('dvs_dmr_display_current_tg')) {
    function dvs_dmr_display_current_tg($abinfo) {
        if (!dvs_dmr_display_is_live_dmr($abinfo)) {
            $state = dvs_dmr_display_read_state();
            return isset($state['tg']) ? trim((string)$state['tg']) : '';
        }
        return dvs_dmr_display_extract_live_tg($abinfo);
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
    print("Replaced existing DMR helper block with v0.4.10")
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

# Patch visible Tx TG row so non-DMR modes show last valid DMR TG instead of wrong-mode target.
old_tx = 'echo "<tr><th>Tx TG</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".$abinfo[\'digital\'][\'tg\']."</td></tr>\\n";'
new_tx = 'echo "<tr><th>Tx TG</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".htmlspecialchars(dvs_dmr_display_current_tg($abinfo), ENT_QUOTES, \'UTF-8\')."</td></tr>\\n";'
if old_tx in text:
    text = text.replace(old_tx, new_tx, 1)
    print("Patched visible Tx TG row using exact hook")
elif new_tx in text:
    print("Visible Tx TG row already patched")
else:
    print("Tx TG row uses current dashboard format; leaving Tx TG unchanged by design")

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
  log "Expected dashboard result: Mode shows DMR network label; DMR Master shows TG name when cache has the TG."
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
  validate_or_restore
  log "Restore protected original files completed"
}

show_status(){
  echo
  echo "${APP_NAME} ${VERSION} status"
  echo "Dashboard root: $DVS_ROOT"
  echo "Status file:    $STATUS_FILE"
  echo "TG cache file:  $TG_CACHE_FILE"
  echo "State file:     $STATE_FILE"
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
  echo "0 = Exit"
  printf "Choose an action [0/1/2/3/4]: "
  read -r choice
  case "$choice" in
    1) apply_cleanup ;;
    2) restore_latest_backup ;;
    3) restore_original ;;
    4) show_status | tee -a "$LOG_FILE"; log "Log file: $LOG_FILE" ;;
    0) exit 0 ;;
    *) die "Invalid choice" ;;
  esac
}

case "${1:-menu}" in
  apply) apply_cleanup ;;
  restore-latest) restore_latest_backup ;;
  restore-original|restore-factory) restore_original ;;
  status) show_status | tee -a "$LOG_FILE"; log "Log file: $LOG_FILE" ;;
  menu|*) main_menu ;;
esac
