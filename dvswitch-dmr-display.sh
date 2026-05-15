#!/usr/bin/env bash
set -u

VERSION="v0.4.18-test"
APP_NAME="DVSwitch Dashboard DMR Display Cleanup"
DVS_ROOT="/usr/share/dvswitch"
STATUS_FILE="${DVS_ROOT}/include/status.php"
TG_CACHE_FILE="${DVS_ROOT}/include/dvs-dmr-talkgroups.tsv"
STATE_DIR="/var/lib/mmdvm/cache"
STATE_FILE="${STATE_DIR}/dmr_last_state.json"
STATE_BY_NET_FILE="${STATE_DIR}/dmr_last_targets.json"
CACHE_UPDATER="/usr/local/sbin/dvs-dashboard-dmr-cache-update"
RESTORE_HELPER="/usr/local/sbin/dvs-dashboard-dmr-target-restore"
CACHE_SERVICE="/etc/systemd/system/dvs-dashboard-dmr-cache-update.service"
CACHE_TIMER="/etc/systemd/system/dvs-dashboard-dmr-cache-update.timer"
RESTORE_SERVICE="/etc/systemd/system/dvs-dashboard-dmr-target-restore.service"
RESTORE_TIMER="/etc/systemd/system/dvs-dashboard-dmr-target-restore.timer"
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
    {
      echo "$APP_NAME original backup"
      echo "Created: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Script version: $VERSION"
      echo "This protected original backup is intentionally never overwritten."
    } > "$ORIG_BACKUP_DIR/README.txt"
  elif [ ! -f "$ORIG_BACKUP_DIR/status.php" ]; then
    log "WARNING: Protected original backup directory exists but status.php is missing. Repairing missing original backup file only."
    cp -a "$STATUS_FILE" "$ORIG_BACKUP_DIR/status.php" || die "Could not repair protected original status.php backup"
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
  if [ -f "$src/dvs-dmr-talkgroups.tsv" ]; then cp -a "$src/dvs-dmr-talkgroups.tsv" "$TG_CACHE_FILE" || die "Could not restore talkgroup cache"; fi
}

validate_or_restore(){
  if php -l "$STATUS_FILE" >/tmp/dvs_dmr_php_lint_status.out 2>&1; then log "PHP syntax check passed for status.php"; return 0; fi
  cat /tmp/dvs_dmr_php_lint_status.out | tee -a "$LOG_FILE"
  log "PHP syntax check failed. Auto-restoring per-run backup: $RUN_BACKUP_DIR"
  restore_from_dir "$RUN_BACKUP_DIR"
  php -l "$STATUS_FILE" >/tmp/dvs_dmr_php_lint_status_restore.out 2>&1 || { cat /tmp/dvs_dmr_php_lint_status_restore.out | tee -a "$LOG_FILE"; die "Restore completed but PHP syntax is still bad. Manual inspection required."; }
  die "Patch rejected and status.php restored cleanly."
}

install_cache_updater(){
  mkdir -p "$(dirname "$CACHE_UPDATER")" "$(dirname "$CACHE_SERVICE")" || die "Could not create updater paths"
  cat > "$CACHE_UPDATER" <<'UPDATER'
#!/usr/bin/env bash
set -u
DEST="/usr/share/dvswitch/include/dvs-dmr-talkgroups.tsv"
TMP="${DEST}.tmp"
mkdir -p "$(dirname "$DEST")"
: > "$TMP"
# Safe starter/fallback entries for common defaults and test TGs.
cat >> "$TMP" <<'SEED'
BM	9	Local/Reflector
BM	91	Worldwide
BM	93	North America
BM	3100	USA Nationwide
TGIF	9050	TGIF 9050
SEED
# TGIF official CSV if available.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://api.tgif.network/dmr/talkgroups/csv 2>/dev/null | awk -F, 'NR>1 {gsub(/\r/,""); id=$1; name=$2; if (id ~ /^[0-9]+$/ && name != "") print "TGIF\t" id "\t" name}' >> "$TMP" || true
  # BrandMeister commonly mirrored JSON/CSV sources can change; keep this optional and non-fatal.
  curl -fsSL https://api.brandmeister.network/v2/talkgroup/ 2>/dev/null | python3 -c 'import sys,json
try:
 data=json.load(sys.stdin)
 if isinstance(data,dict): data=data.get("data",data.get("talkgroups",[]))
 for x in data if isinstance(data,list) else []:
  tid=str(x.get("id",x.get("talkgroup",x.get("tg", "")))).strip()
  name=str(x.get("name",x.get("label", ""))).strip()
  if tid.isdigit() and name: print(f"BM\t{tid}\t{name}")
except Exception: pass
' >> "$TMP" || true
elif command -v wget >/dev/null 2>&1; then
  wget -qO- https://api.tgif.network/dmr/talkgroups/csv 2>/dev/null | awk -F, 'NR>1 {gsub(/\r/,""); id=$1; name=$2; if (id ~ /^[0-9]+$/ && name != "") print "TGIF\t" id "\t" name}' >> "$TMP" || true
fi
awk -F '\t' 'NF>=3 && $2 ~ /^[0-9]+$/ { key=toupper($1) "\t" $2; if (!seen[key]++) print $1 "\t" $2 "\t" $3 }' "$TMP" > "${TMP}.dedup"
mv "${TMP}.dedup" "$DEST"
rm -f "$TMP"
chmod 0644 "$DEST"
wc -l < "$DEST"
UPDATER
  chmod 0755 "$CACHE_UPDATER"

  cat > "$CACHE_SERVICE" <<EOF2
[Unit]
Description=Update DVSwitch Dashboard DMR talkgroup name cache
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CACHE_UPDATER
EOF2
  cat > "$CACHE_TIMER" <<'EOF2'
[Unit]
Description=Weekly DVSwitch Dashboard DMR talkgroup cache update

[Timer]
OnBootSec=5min
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload || true
  systemctl enable --now dvs-dashboard-dmr-cache-update.timer >/dev/null 2>&1 || true
  log "Installed/enabled automatic weekly DMR cache update timer: $CACHE_TIMER"
}

update_cache(){
  need_root
  install_cache_updater
  log "Updating DMR talkgroup name cache: $TG_CACHE_FILE"
  "$CACHE_UPDATER" | tee -a "$LOG_FILE"
  [ -s "$TG_CACHE_FILE" ] || die "DMR talkgroup cache update failed or produced an empty file"
  log "Updated DMR talkgroup cache: $TG_CACHE_FILE"
  log "Cache line count: $(wc -l < "$TG_CACHE_FILE")"
}

install_restore_helper(){
  mkdir -p "$(dirname "$RESTORE_HELPER")" "$(dirname "$RESTORE_SERVICE")" "$STATE_DIR" || die "Could not create restore helper paths"
  cat > "$RESTORE_HELPER" <<'RESTORE'
#!/usr/bin/env bash
set -u
STATE="/var/lib/mmdvm/cache/dmr_last_targets.json"
LEGACY="/var/lib/mmdvm/cache/dmr_last_state.json"
DVS="/opt/MMDVM_Bridge/dvswitch.sh"
[ -x "$DVS" ] || exit 0
[ -s "$STATE" ] || exit 0
MODE=""
if [ -s /tmp/ABInfo_31001.json ]; then MODE=$(python3 - <<'PY' 2>/dev/null
import json
p='/tmp/ABInfo_31001.json'
try:
 d=json.load(open(p)); print(str(d.get('tlv',{}).get('ambe_mode','')).upper())
except Exception: pass
PY
); fi
[ "$MODE" = "DMR" ] || exit 0
# Prefer currently saved current_network, else legacy network.
NET=$(python3 - <<'PY' 2>/dev/null
import json
for p in ['/var/lib/mmdvm/cache/dmr_last_state.json','/var/lib/mmdvm/cache/dmr_last_targets.json']:
 try:
  d=json.load(open(p));
  n=d.get('network') or d.get('current_network')
  if n: print(n); raise SystemExit
 except SystemExit: raise
 except Exception: pass
PY
)
[ -n "$NET" ] || exit 0
TG=$(python3 - "$NET" <<'PY' 2>/dev/null
import json,sys
net=sys.argv[1].upper()
p='/var/lib/mmdvm/cache/dmr_last_targets.json'
try:
 d=json.load(open(p)); x=d.get(net) or d.get(net.title()) or {}; print(str(x.get('tg','')))
except Exception: pass
PY
)
case "$TG" in ''|0) exit 0;; esac
if [ "$TG" = "9" ] && [ "$NET" != "BM" ]; then exit 0; fi
"$DVS" tune "$TG" >/dev/null 2>&1 || true
RESTORE
  chmod 0755 "$RESTORE_HELPER"
  cat > "$RESTORE_SERVICE" <<EOF2
[Unit]
Description=Restore last valid DVSwitch DMR target
After=analog_bridge.service mmdvm_bridge.service

[Service]
Type=oneshot
ExecStart=$RESTORE_HELPER
EOF2
  cat > "$RESTORE_TIMER" <<'EOF2'
[Unit]
Description=Periodic restore of last valid DVSwitch DMR target

[Timer]
OnBootSec=90sec
OnUnitActiveSec=2min
Persistent=false

[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload || true
  systemctl enable --now dvs-dashboard-dmr-target-restore.timer >/dev/null 2>&1 || true
  log "Installed/enabled automatic DMR last-target restore timer: $RESTORE_TIMER"
}

validate_saved_state_interactive(){
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_FILE" "$STATE_BY_NET_FILE" "$TG_CACHE_FILE" <<'PY'
import json,sys,os
legacy,by_net,cache=sys.argv[1:4]
valid_nets={'BM','TGIF','FREEDMR','DMR+','SYSTEMX','STFU'}
def netkey(n):
 s=str(n or '').upper().replace(' ','')
 if 'TGIF' in s: return 'TGIF'
 if 'STFU' in s: return 'BM'
 if 'BRANDMEISTER' in s or s.startswith('BM'): return 'BM'
 if 'FREEDMR' in s: return 'FREEDMR'
 if 'DMR+' in s or 'DMRPLUS' in s: return 'DMR+'
 if 'SYSTEMX' in s or 'SYSTEMX' in s: return 'SYSTEMX'
 return s or 'DMR'
def valid(net,tg,has_existing=False):
 tg=str(tg or '').strip()
 if not tg.isdigit() or tg=='0': return False
 if tg=='9' and net!='BM': return False
 return True
state={}
if os.path.exists(by_net):
 try: state=json.load(open(by_net))
 except Exception: state={}
if os.path.exists(legacy):
 try:
  d=json.load(open(legacy)); n=netkey(d.get('network')); tg=str(d.get('tg','')).strip()
  if valid(n,tg):
   state[n]={'tg':tg,'name':d.get('name',''),'master':d.get('master',''),'updated':d.get('updated','')}
   state['current_network']=n
 except Exception: pass
os.makedirs(os.path.dirname(by_net),exist_ok=True)
json.dump(state,open(by_net,'w'),indent=4)
PY
  # If legacy exists with invalid current selected TG, ask now.
  if [ -s "$STATE_FILE" ]; then
    net="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("network","")).upper())' "$STATE_FILE" 2>/dev/null || true)"
    tg="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("tg","")).strip())' "$STATE_FILE" 2>/dev/null || true)"
    invalid=0
    case "$tg" in ''|0) invalid=1;; 9) [ "$net" != "BM" ] && invalid=1;; esac
    if [ "$invalid" -eq 1 ]; then
      echo
      echo "Saved ${net:-DMR} target is invalid for this mode: ${tg:-empty}"
      printf "Enter a valid ${net:-DMR} talkgroup/reflector to save now, or press Enter to keep display-only mode: "
      read -r newtg
      if echo "$newtg" | grep -Eq '^[0-9]+$' && [ "$newtg" != "0" ] && { [ "$newtg" != "9" ] || [ "$net" = "BM" ]; }; then
        name="$(awk -F '\t' -v n="$net" -v t="$newtg" 'toupper($1)==toupper(n) && $2==t {print $3; exit}' "$TG_CACHE_FILE" 2>/dev/null || true)"
        python3 - "$STATE_FILE" "$STATE_BY_NET_FILE" "$net" "$newtg" "$name" <<'PY'
import json,sys,os,datetime
legacy,by_net,net,tg,name=sys.argv[1:6]
state={}
try: state=json.load(open(by_net))
except Exception: pass
entry={'network':net,'tg':tg,'name':name,'master':net+' Network','updated':datetime.datetime.now(datetime.timezone.utc).isoformat()}
state[net]=entry; state['current_network']=net
os.makedirs(os.path.dirname(by_net),exist_ok=True)
json.dump(state,open(by_net,'w'),indent=4)
json.dump(entry,open(legacy,'w'),indent=4)
PY
        log "Saved user-provided valid $net target: $newtg"
        /opt/MMDVM_Bridge/dvswitch.sh tune "$newtg" >/dev/null 2>&1 || true
      else
        log "No valid replacement target entered; keeping saved state unchanged for now."
      fi
    fi
  fi
}

patch_status_php(){
  log "Applying ${APP_NAME} ${VERSION}"
  log "Scope: DMR display only. Hooks required visible Mode / DMR Master rows and protects DMR state from non-DMR modes."
  mkdir -p "$STATE_DIR" || die "Could not create state directory: $STATE_DIR"
  chown www-data:www-data "$STATE_DIR" 2>/dev/null || true
  chmod 775 "$STATE_DIR" 2>/dev/null || true

  python3 - "$STATUS_FILE" <<'PY'
import re,sys
from pathlib import Path
path=Path(sys.argv[1]); text=path.read_text()
helper=r'''
// DVS-DMR-DISPLAY-CLEANUP v0.4.18-test
// Display-only helpers. No routing/startup config is changed. TG 0 and invalid fallback TG 9 cannot overwrite saved DMR targets.
if (!function_exists('dvs_dmr_display_state_file')) { function dvs_dmr_display_state_file() { return '/var/lib/mmdvm/cache/dmr_last_state.json'; } }
if (!function_exists('dvs_dmr_display_targets_file')) { function dvs_dmr_display_targets_file() { return '/var/lib/mmdvm/cache/dmr_last_targets.json'; } }
if (!function_exists('dvs_dmr_display_network_key')) { function dvs_dmr_display_network_key($dmrMasterHost) { $s=strtoupper(str_replace('_',' ',(string)$dmrMasterHost)); if (strpos($s,'TGIF')!==false) return 'TGIF'; if (strpos($s,'STFU')!==false) return 'BM'; if (strpos($s,'BRANDMEISTER')!==false || strpos($s,'BM ')===0 || strpos($s,'BM-')===0 || strpos($s,'BM')===0) return 'BM'; if (strpos($s,'FREEDMR')!==false || strpos($s,'FREE DMR')!==false) return 'FreeDMR'; if (strpos($s,'DMR+')!==false || strpos($s,'DMRPLUS')!==false || strpos($s,'DMR PLUS')!==false) return 'DMR+'; if (strpos($s,'SYSTEM X')!==false || strpos($s,'SYSTEMX')!==false) return 'SystemX'; return 'DMR'; } }
if (!function_exists('dvs_dmr_display_is_live_dmr')) { function dvs_dmr_display_is_live_dmr($abinfo) { $mode=isset($abinfo['tlv']['ambe_mode'])?trim((string)$abinfo['tlv']['ambe_mode']):''; return strtoupper($mode)==='DMR'; } }
if (!function_exists('dvs_dmr_display_extract_live_tg')) { function dvs_dmr_display_extract_live_tg($abinfo) { $tg=isset($abinfo['digital']['tg'])?trim((string)$abinfo['digital']['tg']):''; if (preg_match('/^\d+$/',$tg)) return $tg; $last=isset($abinfo['last_tune'])?trim((string)$abinfo['last_tune']):''; if (preg_match('/^TG\s*(\d+)$/i',$last,$m)) return $m[1]; if (preg_match('/^\d+$/',$last)) return $last; return ''; } }
if (!function_exists('dvs_dmr_display_read_json')) { function dvs_dmr_display_read_json($file) { if (!is_readable($file)) return array(); $raw=file_get_contents($file); $d=json_decode($raw,true); return is_array($d)?$d:array(); } }
if (!function_exists('dvs_dmr_display_write_json')) { function dvs_dmr_display_write_json($file,$data) { $dir=dirname($file); if (!is_dir($dir)) @mkdir($dir,0775,true); if (!is_dir($dir)||!is_writable($dir)) return false; $tmp=$file.'.tmp'; $p=json_encode($data,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES); if ($p===false) return false; if (@file_put_contents($tmp,$p."\n",LOCK_EX)===false) return false; @chmod($tmp,0664); return @rename($tmp,$file); } }
if (!function_exists('dvs_dmr_display_lookup_name')) { function dvs_dmr_display_lookup_name($network,$id) { $cache=dirname(__FILE__).'/dvs-dmr-talkgroups.tsv'; if (!is_readable($cache)) return ''; $network=trim((string)$network); $id=trim((string)$id); foreach (file($cache,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line) { if (trim($line)==='' || strpos(trim($line),'#')===0) continue; $p=explode("\t",$line,3); if (count($p)>=3 && strcasecmp(trim($p[0]),$network)===0 && trim($p[1])===$id) return trim($p[2]); } return ''; } }
if (!function_exists('dvs_dmr_display_valid_tg')) { function dvs_dmr_display_valid_tg($network,$tg,$hasSaved) { $tg=trim((string)$tg); if ($tg==='' || !preg_match('/^\d+$/',$tg) || $tg==='0') return false; if ($tg==='9' && strtoupper((string)$network)!=='BM') return false; if ($tg==='9' && $hasSaved) return false; return true; } }
if (!function_exists('dvs_dmr_display_targets_read')) { function dvs_dmr_display_targets_read() { return dvs_dmr_display_read_json(dvs_dmr_display_targets_file()); } }
if (!function_exists('dvs_dmr_display_saved_for_network')) { function dvs_dmr_display_saved_for_network($network) { $all=dvs_dmr_display_targets_read(); $k=strtoupper((string)$network); if (isset($all[$k]) && is_array($all[$k])) return $all[$k]; return array(); } }
if (!function_exists('dvs_dmr_display_write_state')) { function dvs_dmr_display_write_state($state) { dvs_dmr_display_write_json(dvs_dmr_display_state_file(),$state); $all=dvs_dmr_display_targets_read(); $k=strtoupper((string)$state['network']); $all[$k]=$state; $all['current_network']=$k; return dvs_dmr_display_write_json(dvs_dmr_display_targets_file(),$all); } }
if (!function_exists('dvs_dmr_display_current_state')) { function dvs_dmr_display_current_state($dmrMasterHost,$abinfo) { $stored=dvs_dmr_display_read_json(dvs_dmr_display_state_file()); if (!dvs_dmr_display_is_live_dmr($abinfo)) return $stored; $network=dvs_dmr_display_network_key($dmrMasterHost); $saved=dvs_dmr_display_saved_for_network($network); $tg=dvs_dmr_display_extract_live_tg($abinfo); $hasSaved=(isset($saved['tg']) && dvs_dmr_display_valid_tg($network,$saved['tg'],false)); if (!dvs_dmr_display_valid_tg($network,$tg,$hasSaved)) { if ($hasSaved) return $saved; return $stored; } $name=dvs_dmr_display_lookup_name($network,$tg); $state=array('network'=>$network,'tg'=>$tg,'name'=>$name,'master'=>(string)$dmrMasterHost,'updated'=>date('c')); dvs_dmr_display_write_state($state); return $state; } }
if (!function_exists('dvs_dmr_display_current_tg')) { function dvs_dmr_display_current_tg($abinfo) { $stored=dvs_dmr_display_read_json(dvs_dmr_display_state_file()); if (!dvs_dmr_display_is_live_dmr($abinfo)) return isset($stored['tg'])?trim((string)$stored['tg']):''; $tg=dvs_dmr_display_extract_live_tg($abinfo); if ($tg==='' || $tg==='0' || $tg==='9') return isset($stored['tg'])?trim((string)$stored['tg']):$tg; return $tg; } }
if (!function_exists('dvs_dmr_display_mode_label')) { function dvs_dmr_display_mode_label($ambeMode,$dmrMasterHost) { if (strtoupper((string)$ambeMode)!=='DMR') return htmlspecialchars((string)$ambeMode,ENT_QUOTES,'UTF-8'); $n=dvs_dmr_display_network_key($dmrMasterHost); if (strpos(strtoupper((string)$dmrMasterHost),'STFU')!==false) return 'STFU/BM'; return htmlspecialchars($n,ENT_QUOTES,'UTF-8'); } }
if (!function_exists('dvs_dmr_display_master_label')) { function dvs_dmr_display_master_label($dmrMasterHost,$abinfo) { $s=dvs_dmr_display_current_state($dmrMasterHost,$abinfo); $network=isset($s['network'])?trim((string)$s['network']):''; $tg=isset($s['tg'])?trim((string)$s['tg']):''; $name=isset($s['name'])?trim((string)$s['name']):''; if ($network==='' || $tg==='') return htmlspecialchars((string)$dmrMasterHost,ENT_QUOTES,'UTF-8'); if ($name!=='') return htmlspecialchars($name,ENT_QUOTES,'UTF-8'); return htmlspecialchars('TG '.$tg,ENT_QUOTES,'UTF-8'); } }
'''.strip()+"\n"
# Remove existing helper block until Status span or include-derived variables.
pat=re.compile(r"// DVS-DMR-DISPLAY-CLEANUP v[0-9.]+-test\s*.*?(?=\?>\s*\n<span style=\"font-weight: bold;font-size:14px;\">Status</span>|\$dmrMasterHost\s*=)",re.S)
text,n=pat.subn(lambda m: helper+"\n",text,count=1)
if n: print('Replaced existing DMR helper block with v0.4.18')
elif 'DVS-DMR-DISPLAY-CLEANUP v0.4.18-test' not in text:
 needle="include_once dirname(dirname(__FILE__)).'/include/functions.php';\n"
 if needle in text:
  text=text.replace(needle,needle+helper+"\n",1); print('Inserted DMR helper block after functions.php include')
 else: raise SystemExit('Could not find functions.php include marker')
old='echo "<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".$abinfo[\'tlv\'][\'ambe_mode\']."</td></tr>\\n";'
new='echo "<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">".dvs_dmr_display_mode_label($abinfo[\'tlv\'][\'ambe_mode\'], $dmrMasterHost)."</td></tr>\\n";'
if old in text: text=text.replace(old,new); print('Patched visible Mode row using exact v0.3 hook')
elif new in text: print('Visible Mode row already patched')
else:
 text,c=re.subn(r'echo\s+"<tr><th width=50%>Mode</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#b44010;\\">"\s*\.\s*\$abinfo\[\'tlv\'\]\[\'ambe_mode\'\]\s*\.\s*"</td></tr>\\n";',lambda m: new,text)
 if c: print('Patched visible Mode row using fallback hook')
 else: raise SystemExit('Could not find visible Mode output line')
newtx='echo "<tr><th width=50%>Tx TG</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#ef7215;\\">".htmlspecialchars(dvs_dmr_display_current_tg($abinfo), ENT_QUOTES, \'UTF-8\')."</td></tr>\\n";'
text,c=re.subn(r'echo\s+"<tr><th width=50%>Tx TG</th><td style=\\"background: #f9f9f9;font-weight: bold;color:#(?:ef7215|b44010);\\">"\s*\.\s*(?:\$abinfo\[\'digital\'\]\[\'tg\'\]|htmlspecialchars\(dvs_dmr_display_current_tg\(\$abinfo\), ENT_QUOTES, \'UTF-8\'\))\s*\.\s*"</td></tr>\\n";',lambda m: newtx,text)
print(f'Patched visible Tx TG row using flexible default-compatible hook ({c} occurrence(s))')
oldm='echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".$dmrMasterHost."</span></td></tr>\\n";}'
newm='echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".dvs_dmr_display_master_label($dmrMasterHost, $abinfo)."</span></td></tr>\\n";}'
if oldm in text: text=text.replace(oldm,newm,1); print('Patched visible DMR Master row using exact v0.3 hook')
elif newm in text: print('Visible DMR Master row already patched')
else:
 repl='echo "<tr><td  style=\\"background: #ffffed;\\" colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">".dvs_dmr_display_master_label($dmrMasterHost, $abinfo)."</span></td></tr>\\n";'
 text,c=re.subn(r'echo\s+"<tr><td\s+style=\\"background: #ffffed;\\"\s+colspan=\\"2\\"><span style=\\"color:#b5651d;font-weight: bold\\">"\s*\.\s*(?:\$dmrMasterHost|dvs_dmr_display_master_label\(\$dmrMasterHost, \$abinfo\))\s*\.\s*"</span></td></tr>\\n";',lambda m: repl,text,count=1)
 if c: print('Patched visible DMR Master row using fallback hook')
 else: raise SystemExit('Could not find visible DMR Master output line')
path.write_text(text)
PY
  [ "$?" -eq 0 ] || die "Could not patch status.php cleanly"
  validate_or_restore
  log "Patched helper block and required visible rows."
  log "Expected dashboard result: Mode shows DMR network label; DMR Master/Tx TG preserve valid per-network TGs, reject invalid TG 0/9, and ask during install if saved target is invalid."
}

restore_latest_backup(){ need_root; latest="$(find "$DVS_ROOT" -maxdepth 1 -type d -name '.dvs-dashboard-dmr-display-cleanup-backup-*' | sort | tail -1)"; [ -n "$latest" ] || die "No per-run backup found"; log "Restoring latest per-run backup: $latest"; restore_from_dir "$latest"; validate_or_restore; log "Restore latest per-run backup completed"; }
restore_original(){
  need_root
  [ -f "$ORIG_BACKUP_DIR/status.php" ] || die "Protected original backup missing status.php: $ORIG_BACKUP_DIR"
  log "Restoring protected original dashboard file backup: $ORIG_BACKUP_DIR"
  restore_from_dir "$ORIG_BACKUP_DIR"
  systemctl disable --now dvs-dashboard-dmr-cache-update.timer dvs-dashboard-dmr-target-restore.timer >/dev/null 2>&1 || true
  rm -f "$CACHE_SERVICE" "$CACHE_TIMER" "$RESTORE_SERVICE" "$RESTORE_TIMER" "$CACHE_UPDATER" "$RESTORE_HELPER"
  systemctl daemon-reload || true
  log "Removed automatic DMR cache/update restore timer/service if present."
  validate_or_restore
  log "Restore protected original files completed"
}
show_status(){
  echo; echo "${APP_NAME} ${VERSION} status"; echo "Dashboard root: $DVS_ROOT"; echo "Status file:    $STATUS_FILE"; echo "TG cache file:  $TG_CACHE_FILE"; echo "State file:     $STATE_FILE"; echo "Per-network:    $STATE_BY_NET_FILE"; echo
  echo "Markers / visible hooks in status.php:"; grep -n "DVS-DMR-DISPLAY-CLEANUP\|dvs_dmr_display_mode_label\|dvs_dmr_display_current_tg\|dvs_dmr_display_master_label" "$STATUS_FILE" 2>/dev/null || true
  echo; echo "Current DMR state file:"; [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "(not created yet)"
  echo; echo "Per-network DMR targets:"; [ -f "$STATE_BY_NET_FILE" ] && cat "$STATE_BY_NET_FILE" || echo "(not created yet)"
  echo; echo "Timers:"; systemctl list-timers 'dvs-dashboard-dmr-*' --no-pager 2>/dev/null || true
}
apply_cleanup(){ need_root; backup_files; update_cache; install_restore_helper; validate_saved_state_interactive; patch_status_php; log "Protected original backup: $ORIG_BACKUP_DIR"; log "Per-run backup: $RUN_BACKUP_DIR"; log "Refresh the DVSwitch Dashboard in the browser."; log "Log file: $LOG_FILE"; }
main_menu(){ echo "${APP_NAME} ${VERSION}"; echo "1 = Apply DMR display cleanup fix"; echo "2 = Restore latest per-run backup"; echo "3 = Restore protected original files"; echo "4 = Show DMR cleanup status markers"; echo "5 = Update DMR talkgroup name cache"; echo "0 = Exit"; printf "Choose an action [0/1/2/3/4/5]: "; read -r choice; case "$choice" in 1) apply_cleanup;; 2) restore_latest_backup;; 3) restore_original;; 4) show_status | tee -a "$LOG_FILE"; log "Log file: $LOG_FILE";; 5) update_cache;; 0) exit 0;; *) die "Invalid choice";; esac; }
case "${1:-menu}" in apply) apply_cleanup;; restore-latest) restore_latest_backup;; restore-original|restore-factory) restore_original;; status) show_status | tee -a "$LOG_FILE"; log "Log file: $LOG_FILE";; update-cache|--update-cache) update_cache;; menu|*) main_menu;; esac
