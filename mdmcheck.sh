#!/bin/sh
# mdmcheck.sh — Remote Management (DEP/MDM) + Activation-Lock checker for a Mac on the bench.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/mdmcheck.sh | zsh
#
# Run it on the unit's OWN macOS, after the temp admin exists. It reports whether this Mac is
# still assigned to Remote Management / DEP or carries Activation Lock, then writes a proof file.
#
# DETECTION / READ-ONLY. It reads status only. It never writes to the disk it inspects, never
# removes a profile, and never suppresses or bypasses the Remote Management or enrollment screen.
#
# PORTABILITY: written to behave IDENTICALLY under bash and zsh. zsh does not word-split unquoted
# variables, so every list is iterated line-by-line instead of relying on splitting, and no globs
# are used (zsh errors on an unmatched glob where bash leaves the literal). Do not "simplify" those
# loops back into `for x in $LIST` — under zsh that silently iterates once with the whole string,
# which would make every "not assigned" receipt look like a management marker and flag clean Macs
# as MANAGED.
#
# Usage:  ... | zsh              normal check
#         ... | zsh -s -- --report    calibration dump, verdict not acted on
#         ... | zsh -s -- --quiet     no dialog, terminal + report only
#
# TEST HOOK: with MDMCHECK_CLASSIFY_ONLY=1 the script skips all gathering, takes AL / DEP_SHOW /
# DEP_SHOW_RC / DEP_STATUS / DISK_STATE / DISK_MARKERS from the environment, prints "VERDICT=<v>"
# and exits. Read-only and side-effect free; it exists so the verdict logic can be driven by the
# same test vectors as the reference implementation and proven identical under both bash and zsh.
set -u

MDMCHECK_VERSION="2.0.0"

# ---------------------------------------------------------------- args (work when piped via -s --)
REPORT_ONLY=0
QUIET=0
for _a in "$@"; do
  case "$_a" in
    --report) REPORT_ONLY=1 ;;
    --quiet)  QUIET=1 ;;
    --version) echo "mdmcheck $MDMCHECK_VERSION"; exit 0 ;;
    -h|--help)
      echo "mdmcheck $MDMCHECK_VERSION — Remote Management / Activation-Lock checker (read-only)"
      echo "  --report   dump raw signals for calibration (verdict not acted on)"
      echo "  --quiet    skip the popup; terminal + report file only"
      exit 0 ;;
  esac
done

# ---------------------------------------------------------------- marker vocabularies
# Keys that prove the cloud query returned a real DEP/ADE enrollment configuration.
MANAGED_MARKERS='configurationurl
organizationname
enrollmenturl
allowpairing
skipsetup
awaitdeviceconfigured
anchorcerts
is_mdm_removable
assignedserver
is_supervised
mdm_service_address'

# Setup Assistant writes a receipt of its DEP check EITHER WAY. These are the "Apple answered: this
# serial is NOT assigned" receipts — present on every clean Mac that completed setup online. They
# are NOT management markers. Treating them as markers is what once flagged clean stock as MANAGED.
DISK_NEGATIVE_MARKERS='.cloudconfigrecordnotfound
.cloudconfignoactivationrecord'

CLEAN_MARKERS='not dep enabled
no enrollment configurations
are no enrollment
no device enrollment
not capable of device enrollment
not enrolled in dep
device is not assigned
no enrollment configuration'

NET_ERROR_MARKERS='timed out
timeout
unreachable
could not connect
cannot connect
network is down
network is unreachable
-1009
-1001
-1004
no internet
offline
nsurlerrordomain
could not reach'

RUN_ERROR_MARKERS='must be running as root
must be run as root
requires root
operation not permitted
permission denied
not permitted'

# The cloud request FAILED to complete — NOT a "not assigned" answer. Seen on genuinely DEP-managed
# devices (Apple error 34000). Must never read as clean.
CLOUD_FAIL_MARKERS='failed to request configuration from the cloud
mccloudconfigurationerrordomain
cloudconfigurationfatalerror
cloudconfigurationerror
code=34000
(34000)'

_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
_trim() { printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# Does haystack ($1) contain any line of the newline-delimited needle list ($2)?
_has_any_line() {
  _hay="$1"
  _found=1
  while IFS= read -r _needle; do
    [ -n "$_needle" ] || continue
    case "$_hay" in *"$_needle"*) _found=0; break ;; esac
  done <<EOF
$2
EOF
  return $_found
}

# ---------------------------------------------------------------- preflight + gather
if [ "${MDMCHECK_CLASSIFY_ONLY:-0}" = "1" ]; then
  # Test hook: values supplied by the caller; no system access, no side effects.
  AL="${AL:-}"; DEP_SHOW="${DEP_SHOW:-}"; DEP_SHOW_RC="${DEP_SHOW_RC:--1}"
  DEP_STATUS="${DEP_STATUS:-}"; DISK_STATE="${DISK_STATE:-notfound}"
  DISK_MARKERS="${DISK_MARKERS:-}"
  SERIAL="TEST"; MODEL="TEST"; OSVER="TEST"
else
if [ "$(uname -s)" != "Darwin" ]; then
  echo "mdmcheck: macOS only." >&2
  exit 1
fi

echo "=============================================================="
echo "  Remote Management / Activation-Lock check  (mdmcheck $MDMCHECK_VERSION)"
echo "  Read-only: reports status, changes nothing."
echo "=============================================================="
echo
echo "Admin rights are needed to read this Mac's enrollment records."
# sudo reads its prompt from the terminal, not stdin, so this is safe while piped.
if ! sudo -v; then
  echo "Could not obtain admin rights; aborting." >&2
  exit 1
fi

# ---------------------------------------------------------------- gather
HW="$(system_profiler SPHardwareDataType 2>/dev/null)"
SERIAL="$(_trim "$(printf '%s\n' "$HW" | awk -F': ' '/Serial Number/{print $2; exit}')")"
MODEL="$(_trim "$(printf '%s\n' "$HW" | awk -F': ' '/Model Name/{print $2; exit}')")"
[ -n "$MODEL" ] || MODEL="$(_trim "$(printf '%s\n' "$HW" | awk -F': ' '/Model Identifier/{print $2; exit}')")"
AL="$(_trim "$(printf '%s\n' "$HW" | awk -F': ' '/Activation Lock Status/{print $2; exit}')")"
OSVER="$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
[ -n "$SERIAL" ] || SERIAL="UNKNOWN"
[ -n "$MODEL" ] || MODEL="Unknown"

DEP_SHOW="$(sudo profiles show -type enrollment 2>&1)"; DEP_SHOW_RC=$?
DEP_STATUS="$(sudo profiles status -type enrollment 2>&1)"

# On-disk activation records of the RUNNING system (this Mac IS the unit under test).
# `find` instead of a glob: identical behaviour in bash and zsh.
DB=/private/var/db
DISK_MARKERS=""
_cc="$(sudo /usr/bin/find "$DB/ConfigurationProfiles/Settings" -maxdepth 1 -name '.cloudConfig*' \
        -exec /usr/bin/basename {} \; 2>/dev/null)"
while IFS= read -r _m; do
  [ -n "$_m" ] || continue
  DISK_MARKERS="${DISK_MARKERS:+$DISK_MARKERS,}$_m"
done <<EOF
$_cc
EOF
sudo /bin/test -e "$DB/com.apple.DEPReceipt" 2>/dev/null \
  && DISK_MARKERS="${DISK_MARKERS:+$DISK_MARKERS,}com.apple.DEPReceipt"
sudo /bin/test -e "$DB/ConfigurationProfiles/Setup/.configuratorEnrollment" 2>/dev/null \
  && DISK_MARKERS="${DISK_MARKERS:+$DISK_MARKERS,}.configuratorEnrollment"

# The records live on the running system, so they are readable by definition.
DISK_STATE="readable"
if [ ! -d "$DB/ConfigurationProfiles" ]; then
  DISK_STATE="notfound"
fi

fi   # end gather (skipped under MDMCHECK_CLASSIFY_ONLY)

# ---------------------------------------------------------------- classify
al="$(_trim "$(_lc "$AL")")"
low_show="$(_lc "$DEP_SHOW")"
low_status="$(_lc "$DEP_STATUS")"
rc="$DEP_SHOW_RC"
case "$rc" in ''|*[!0-9-]*) rc=-1 ;; esac

al_enabled=0;    [ "$al" = "enabled" ] && al_enabled=1
dep_status_yes=0
case "$low_status" in *"enrolled via dep: yes"*) dep_status_yes=1 ;; esac

show_has_config=0
if [ "$rc" = "0" ] && _has_any_line "$low_show" "$MANAGED_MARKERS"; then
  show_has_config=1
fi

disk_managed_list=""
disk_negative_list=""
while IFS= read -r _m; do
  _m="$(_trim "$_m")"
  [ -n "$_m" ] || continue
  _ml="$(_lc "$_m")"
  _neg=0
  while IFS= read -r _n; do
    [ -n "$_n" ] || continue
    [ "$_ml" = "$_n" ] && { _neg=1; break; }
  done <<EOF
$DISK_NEGATIVE_MARKERS
EOF
  if [ "$_neg" = "1" ]; then
    disk_negative_list="${disk_negative_list:+$disk_negative_list, }$_m"
  else
    disk_managed_list="${disk_managed_list:+$disk_managed_list, }$_m"
  fi
done <<EOF
$(printf '%s' "$DISK_MARKERS" | tr ',' '\n')
EOF

disk_managed=0;  [ -n "$disk_managed_list" ] && disk_managed=1
disk_readable=0; [ "$DISK_STATE" = "readable" ] && disk_readable=1

managed=0
if [ "$disk_managed" = "1" ] || [ "$al_enabled" = "1" ] \
   || [ "$show_has_config" = "1" ] || [ "$dep_status_yes" = "1" ]; then
  managed=1
fi

if [ "$managed" = "1" ]; then
  VERDICT="MANAGED"
elif [ "$disk_readable" = "1" ]; then
  VERDICT="CLEAN"
else
  VERDICT="NOT CONFIRMED"
fi

if [ "${MDMCHECK_CLASSIFY_ONLY:-0}" = "1" ]; then
  printf 'VERDICT=%s\n' "$VERDICT"
  exit 0
fi

# ---------------------------------------------------------------- reasons
REASONS=""
_add() { REASONS="${REASONS:+$REASONS
}$1"; }
if [ "$managed" = "1" ]; then
  [ "$disk_managed" = "1" ] && _add "On-disk DEP/MDM records on this Mac: $disk_managed_list"
  [ "$al_enabled" = "1" ] && _add "Activation Lock: Enabled"
  [ "$show_has_config" = "1" ] && _add "DEP/ADE enrollment configuration returned by the cloud query"
  [ "$dep_status_yes" = "1" ] && _add "Local status reports Enrolled via DEP: Yes"
elif [ "$VERDICT" = "CLEAN" ]; then
  _add "Read this Mac's DEP/MDM activation records directly — none present (on-disk ground truth). Activation Lock not enabled."
  [ -n "$disk_negative_list" ] && _add "On-disk Apple receipt confirms the DEP check ran and returned not-assigned: $disk_negative_list"
else
  _add "NOT a clearance — the management records could not be read, and the DEP cloud query is unreliable. CONFIRM at the Setup Assistant 'Remote Management' screen before processing."
  if _has_any_line "$low_show" "$CLOUD_FAIL_MARKERS"; then
    _add "(cloud) DEP query FAILED to reach Apple (e.g. error 34000)"
  elif _has_any_line "$low_show" "$RUN_ERROR_MARKERS"; then
    _add "(cloud) DEP query could not run (needs root)"
  elif _has_any_line "$low_show" "$NET_ERROR_MARKERS"; then
    _add "(cloud) DEP query failed (offline / network)"
  elif _has_any_line "$low_show" "$CLEAN_MARKERS"; then
    _add "(cloud) DEP query returned 'not assigned' — but that answer is NOT reliable"
  fi
  _add "Activation Lock: ${AL:-not reported}"
fi

# ---------------------------------------------------------------- calibration dump
if [ "$REPORT_ONLY" = "1" ]; then
  echo "== mdmcheck --report (calibration; verdict NOT acted on) =="
  echo "Serial: $SERIAL   Model: $MODEL   macOS: $OSVER"
  echo "Activation Lock raw: '$AL'"
  echo "Disk state: $DISK_STATE   markers: '${DISK_MARKERS:-none}'"
  echo "profiles show rc: $DEP_SHOW_RC"
  echo "--- profiles show -type enrollment ---"; printf '%s\n' "${DEP_SHOW:-(no output)}"
  echo "--- profiles status -type enrollment ---"; printf '%s\n' "${DEP_STATUS:-(no output)}"
  echo "--- would-be verdict ---"; echo "  $VERDICT"
  exit 0
fi

# ---------------------------------------------------------------- present
case "$VERDICT" in
  MANAGED)
    COLOR=$'\033[1;31m'; ICON=caution
    ACTION="ACTION: MANAGED - record the serial on the client release list and apply the managed-unit pre-work. Erase is NOT blocked."
    ;;
  CLEAN)
    COLOR=$'\033[1;32m'; ICON=note
    ACTION="ACTION: Clean (read directly from this Mac's records). OK to proceed to Erase."
    ;;
  *)
    COLOR=$'\033[1;33m'; ICON=caution
    ACTION="ACTION: NOT cleared. Could not read the management records — confirm at the Setup Assistant 'Remote Management' screen before processing."
    ;;
esac
RESET=$'\033[0m'

echo
echo "  Serial : $SERIAL"
echo "  Model  : $MODEL"
echo "  macOS  : $OSVER"
echo "  Verdict: ${COLOR}${VERDICT}${RESET}"
printf '%s\n' "$REASONS" | while IFS= read -r r; do [ -n "$r" ] && echo "     - $r"; done
echo
echo "  $ACTION"
echo

# ---------------------------------------------------------------- proof file
TS="$(date '+%Y-%m-%d %H:%M:%S')"
SAFE_SERIAL="$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9_-' '_')"
RDIR="$HOME/Desktop/MDM Checks"
WROTE=""
if mkdir -p "$RDIR" 2>/dev/null; then
  RPATH="$RDIR/${SAFE_SERIAL}_$(date '+%Y%m%d-%H%M%S').txt"
  {
    echo "Remote Management / Activation-Lock detection report"
    echo "============================================================"
    echo "Timestamp : $TS"
    echo "Serial    : $SERIAL"
    echo "Model     : $MODEL"
    echo "macOS     : $OSVER"
    echo "Checker   : mdmcheck $MDMCHECK_VERSION (run on the unit's own OS)"
    echo "Verdict   : $VERDICT"
    echo "Records   : $DISK_STATE"
    echo
    echo "Findings:"
    printf '%s\n' "$REASONS" | while IFS= read -r r; do [ -n "$r" ] && echo "  - $r"; done
    echo
    echo "$ACTION"
    echo
    echo "------------------------------------------------------------"
    echo "Raw: profiles show -type enrollment (rc=$DEP_SHOW_RC)"
    printf '%s\n' "${DEP_SHOW:-(no output)}"
    echo
    echo "Raw: profiles status -type enrollment"
    printf '%s\n' "${DEP_STATUS:-(no output)}"
  } > "$RPATH" 2>/dev/null && WROTE="$RPATH"
  printf '%s  %-16s  %-26s  %s\n' "$TS" "$SERIAL" "$MODEL" "$VERDICT" \
    >> "$RDIR/mdm_checks.txt" 2>/dev/null
fi
if [ -n "$WROTE" ]; then
  echo "  Report : $WROTE"
else
  echo "  Report : FAILED to write"
fi
echo
echo "  NOTE: this proof lives on a disk that is about to be erased —"
echo "        record the verdict on the unit ticket BEFORE wiping."
echo

# ---------------------------------------------------------------- popup
if [ "$QUIET" != "1" ]; then
  MSG="Serial: $SERIAL
Model: $MODEL
macOS: $OSVER

Verdict: $VERDICT

$(printf '%s\n' "$REASONS" | sed 's/^/- /')

$ACTION"
  [ -n "$WROTE" ] && MSG="$MSG

Saved: $WROTE"
  AS_MSG="$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/' \
            | paste -sd'&' - | sed 's/&/ \& return \& /g')"
  osascript -e "display dialog $AS_MSG with title \"MDM Check - $VERDICT\" buttons {\"OK\"} default button \"OK\" with icon $ICON" >/dev/null 2>&1
fi

exit 0
