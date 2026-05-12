#!/usr/bin/env bash
set -u

VERSION="v0.4.7-test"
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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Please run with sudo/root."
        exit 1
    fi
}

lint_status() {
    php -l "$STATUS_FILE" >/tmp/dvs_dmr_php_lint_status.out 2>&1
}

backup_files() {
    [ -f "$STATUS_FILE" ] || die "Missing dashboard status file: $STATUS_FILE"

    if [ ! -d "$ORIG_BACKUP_DIR" ]; then
        log "Creating protected original dashboard backup: $ORIG_BACKUP_DIR"
        mkdir -p "$ORIG_BACKUP_DIR" || die "Could not create protected original backup directory"
        cp -a "$STATUS_FILE" "$ORIG_BACKUP_DIR/status.php" || die "Could not backup original status.php"
        [ -f "$TG_CACHE_FILE" ] && cp -a "$TG_CACHE_FILE" "$ORIG_BACKUP_DIR/dvs-dmr-talkgroups.tsv"
    elif [ ! -f "$ORIG_BACKUP_DIR/status.php" ]; then
        log "WARNING: Protected original backup directory exists but status.php is missing."
        if lint_status; then
            log "Repairing missing protected status.php backup from the current lint-clean status.php."
            cp -a "$STATUS_FILE" "$ORIG_BACKUP_DIR/status.php" || die "Could not repair missing protected original status.php backup"
            [ -f "$TG_CACHE_FILE" ] && cp -a "$TG_CACHE_FILE" "$ORIG_BACKUP_DIR/dvs-dmr-talkgroups.tsv"
        else
            cat /tmp/dvs_dmr_php_lint_status.out | tee -a "$LOG_FILE"
            die "Current status.php is not lint-clean; refusing to repair protected backup"
        fi
    else
        log "Protected original backup already exists and will NOT be overwritten: $ORIG_BACKUP_DIR"
    fi

    log "Creating per-run backup: $RUN_BACKUP_DIR"
    mkdir -p "$RUN_BACKUP_DIR" || die "Could not create per-run backup directory"
    cp -a "$STATUS_FILE" "$RUN_BACKUP_DIR/status.php" || die "Could not backup status.php"
    [ -f "$TG_CACHE_FILE" ] && cp -a "$TG_CACHE_FILE" "$RUN_BACKUP_DIR/dvs-dmr-talkgroups.tsv"
}

restore_run_backup_now() {
    if [ -f "$RUN_BACKUP_DIR/status.php" ]; then
        cp -a "$RUN_BACKUP_DIR/status.php" "$STATUS_FILE" || true
        log "Auto-restored status.php from this run backup after failure: $RUN_BACKUP_DIR"
    fi
}

patch_status_php() {
    log "Applying ${APP_NAME} ${VERSION}"
    log "Scope: DMR only. Non-DMR modes must not overwrite the DMR cache/display state."
    log "Patch strategy: install helper block, then safely override display variables before stock rows render."

    mkdir -p "$STATE_DIR" || die "Could not create state directory: $STATE_DIR"
    chown www-data:www-data "$STATE_DIR" 2>/dev/null || true
    chmod 775 "$STATE_DIR" 2>/dev/null || true

    python3 - "$STATUS_FILE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

version = "v0.4.7-test"
start_marker = "// DVS-DMR-DISPLAY-CLEANUP START"
end_marker = "// DVS-DMR-DISPLAY-CLEANUP END"

block = r'''// DVS-DMR-DISPLAY-CLEANUP START
// DVS-DMR-DISPLAY-CLEANUP v0.4.7-test
// Display-only helpers. No tuning, routing, startup TG, or network config is changed.
// DMR state is updated ONLY when ABInfo reports ambe_mode=DMR.
// Non-DMR modes keep the last valid DMR network/TG/name.
// v0.4.7 avoids fragile HTML-row rewriting by overriding stock display variables before render.

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
        if (is_array($abinfo) && isset($abinfo['tlv']['ambe_mode'])) {
            $mode = trim((string)$abinfo['tlv']['ambe_mode']);
        }
        return strtoupper($mode) === 'DMR';
    }
}

if (!function_exists('dvs_dmr_display_extract_live_tg')) {
    function dvs_dmr_display_extract_live_tg($abinfo) {
        $tg = is_array($abinfo) && isset($abinfo['digital']['tg']) ? trim((string)$abinfo['digital']['tg']) : '';
        if (preg_match('/^\d+$/', $tg)) { return $tg; }

        $lastTune = is_array($abinfo) && isset($abinfo['last_tune']) ? trim((string)$abinfo['last_tune']) : '';
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

        if (!is_dir($dir)) {
            @mkdir($dir, 0775, true);
        }

        if (!is_dir($dir) || !is_writable($dir)) {
            return false;
        }

        $payload = json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        if ($payload === false) { return false; }

        $tmp = $file . '.tmp';
        if (@file_put_contents($tmp, $payload . "\n", LOCK_EX) === false) {
            return false;
        }

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

if (!function_exists('dvs_dmr_display_mode_plain')) {
    function dvs_dmr_display_mode_plain($ambeMode, $dmrMasterHost) {
        if (strtoupper((string)$ambeMode) !== 'DMR') {
            return (string)$ambeMode;
        }
        return dvs_dmr_display_network_key($dmrMasterHost);
    }
}

if (!function_exists('dvs_dmr_display_master_plain')) {
    function dvs_dmr_display_master_plain($dmrMasterHost, $abinfo) {
        $state = dvs_dmr_display_current_state($dmrMasterHost, $abinfo);

        $network = isset($state['network']) ? trim((string)$state['network']) : '';
        $tg = isset($state['tg']) ? trim((string)$state['tg']) : '';
        $name = isset($state['name']) ? trim((string)$state['name']) : '';

        if ($network === '' || $tg === '') {
            return (string)$dmrMasterHost;
        }

        if ($name !== '') {
            return $name;
        }

        return 'TG ' . $tg;
    }
}

// Safe stock-display variable override. This avoids editing the dashboard HTML rows.
if (isset($abinfo) && is_array($abinfo) && isset($dmrMasterHost)) {
    $__dvs_dmr_display_original_master = $dmrMasterHost;
    $__dvs_dmr_display_original_mode = isset($abinfo['tlv']['ambe_mode']) ? $abinfo['tlv']['ambe_mode'] : '';
    $__dvs_dmr_display_master_label = dvs_dmr_display_master_plain($__dvs_dmr_display_original_master, $abinfo);
    $__dvs_dmr_display_mode_label = dvs_dmr_display_mode_plain($__dvs_dmr_display_original_mode, $__dvs_dmr_display_original_master);

    $dmrMasterHost = htmlspecialchars($__dvs_dmr_display_master_label, ENT_QUOTES, 'UTF-8');
    if (!isset($abinfo['tlv']) || !is_array($abinfo['tlv'])) { $abinfo['tlv'] = array(); }
    $abinfo['tlv']['ambe_mode'] = htmlspecialchars($__dvs_dmr_display_mode_label, ENT_QUOTES, 'UTF-8');
}
// DVS-DMR-DISPLAY-CLEANUP END
'''

# Remove any previous helper block, including older versions that did not have START/END.
text2, count = re.subn(
    r"// DVS-DMR-DISPLAY-CLEANUP START\s*.*?// DVS-DMR-DISPLAY-CLEANUP END\s*",
    "",
    text,
    flags=re.S,
)
text = text2

text2, old_count = re.subn(
    r"// DVS-DMR-DISPLAY-CLEANUP v[0-9.]+-test\s*"
    r"// Display-only helpers\. No tuning, routing, startup TG, or network config is changed\.\s*"
    r".*?(?=\n\?>\s*\n<span style=\"font-weight: bold;font-size:14px;\">Status</span>)",
    "",
    text,
    count=1,
    flags=re.S,
)
text = text2

# Insert the helper immediately before the Status HTML begins, which is where the stock variables are already available.
anchor = '\n?>\n<span style="font-weight: bold;font-size:14px;">Status</span>'
if anchor not in text:
    print("Could not find stock Status anchor in status.php")
    sys.exit(2)

text = text.replace(anchor, "\n" + block + anchor, 1)
path.write_text(text)
print(f"Installed DMR display helper block {version}; removed newer/older helper blocks first")
print("Patched strategy: no direct HTML row rewrite; stock variables are overridden safely before render")
PY
    rc=$?
    if [ "$rc" -ne 0 ]; then
        restore_run_backup_now
        die "Could not patch status.php cleanly"
    fi

    if ! lint_status; then
        cat /tmp/dvs_dmr_php_lint_status.out | tee -a "$LOG_FILE"
        restore_run_backup_now
        die "PHP syntax check failed for status.php; restored this run backup"
    fi

    log "PHP syntax check passed for status.php"
    log "Installed helper block and safe display-variable override."
    log "Expected visible result in DMR: Mode should show TGIF/BM/etc.; DMR Master should show TG name or TG number."
    log "DMR state file: $STATE_FILE"
}

restore_latest_backup() {
    latest="$(find "$DVS_ROOT" -maxdepth 1 -type d -name '.dvs-dashboard-dmr-display-cleanup-backup-*' | sort | tail -1)"
    [ -n "$latest" ] || die "No per-run backup found"
    [ -f "$latest/status.php" ] || die "Latest backup missing status.php: $latest"

    log "Restoring latest per-run backup: $latest"
    cp -a "$latest/status.php" "$STATUS_FILE" || die "Could not restore status.php"
    if ! lint_status; then
        cat /tmp/dvs_dmr_php_lint_status.out | tee -a "$LOG_FILE"
        die "PHP syntax check failed after restore"
    fi
    log "Restore latest per-run backup completed"
}

restore_original() {
    [ -f "$ORIG_BACKUP_DIR/status.php" ] || die "Protected original backup missing status.php: $ORIG_BACKUP_DIR"

    log "Restoring protected original dashboard file backup: $ORIG_BACKUP_DIR"
    cp -a "$ORIG_BACKUP_DIR/status.php" "$STATUS_FILE" || die "Could not restore original status.php"
    if ! lint_status; then
        cat /tmp/dvs_dmr_php_lint_status.out | tee -a "$LOG_FILE"
        die "PHP syntax check failed after original restore"
    fi
    log "Restore protected original files completed"
}

show_status() {
    echo
    echo "${APP_NAME} ${VERSION} status"
    echo "Dashboard root: $DVS_ROOT"
    echo "Status file:    $STATUS_FILE"
    echo "State file:     $STATE_FILE"
    echo
    echo "Markers in status.php:"
    grep -n "DVS-DMR-DISPLAY-CLEANUP\|dvs_dmr_display_current_state\|dvs_dmr_display_is_live_dmr\|dvs_dmr_display_state_file\|dvs_dmr_display_mode_plain\|dvs_dmr_display_master_plain" "$STATUS_FILE" 2>/dev/null || true
    echo
    echo "Current DMR state file:"
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "(not created yet)"
    fi
    echo
    echo "Protected original backup:"
    if [ -f "$ORIG_BACKUP_DIR/status.php" ]; then
        echo "$ORIG_BACKUP_DIR"
    elif [ -d "$ORIG_BACKUP_DIR" ]; then
        echo "$ORIG_BACKUP_DIR (directory exists but status.php is missing)"
    else
        echo "(not created yet)"
    fi
    echo
    echo "Latest per-run backup:"
    find "$DVS_ROOT" -maxdepth 1 -type d -name '.dvs-dashboard-dmr-display-cleanup-backup-*' | sort | tail -1
}

main_menu() {
    echo "${APP_NAME} ${VERSION}"
    echo "1 = Apply DMR display cleanup fix"
    echo "2 = Restore latest per-run backup"
    echo "3 = Restore protected original files"
    echo "4 = Show DMR cleanup status markers"
    echo "0 = Exit"
    printf "Choose an action [0/1/2/3/4]: "
    read -r choice

    case "$choice" in
        1)
            backup_files
            patch_status_php
            log "Protected original backup: $ORIG_BACKUP_DIR"
            log "Per-run backup: $RUN_BACKUP_DIR"
            log "DMR state file: $STATE_FILE"
            log "Refresh the DVSwitch Dashboard in the browser."
            log "Log file: $LOG_FILE"
            ;;
        2)
            restore_latest_backup
            log "Log file: $LOG_FILE"
            ;;
        3)
            restore_original
            log "Log file: $LOG_FILE"
            ;;
        4)
            show_status | tee -a "$LOG_FILE"
            log "Log file: $LOG_FILE"
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid choice."
            exit 1
            ;;
    esac
}

need_root
case "${1:-menu}" in
    apply)
        backup_files
        patch_status_php
        log "Protected original backup: $ORIG_BACKUP_DIR"
        log "Per-run backup: $RUN_BACKUP_DIR"
        log "DMR state file: $STATE_FILE"
        log "Refresh the DVSwitch Dashboard in the browser."
        log "Log file: $LOG_FILE"
        ;;
    restore-latest)
        restore_latest_backup
        log "Log file: $LOG_FILE"
        ;;
    restore-original|restore-factory)
        restore_original
        log "Log file: $LOG_FILE"
        ;;
    status)
        show_status | tee -a "$LOG_FILE"
        log "Log file: $LOG_FILE"
        ;;
    menu|*)
        main_menu
        ;;
esac
