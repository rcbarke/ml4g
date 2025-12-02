#!/usr/bin/env bash
# oai_prb_dos.sh
# Steps 1–4 for the 3‑UE DoS demo on OAI:
#  1) UE1 & UE2 honest traffic for full duration (default 240s)
#  2) Start DoS from UE3 at t=attack_start with (Ton,Toff,rate,parallel)
#  3) Stop DoS at t=duration-recovery; last 'recovery' seconds are UE1/UE2 only
#  4) Post-process Jain’s: per-second (iperf JSON) and per-TTI (PRB log)
#
# Reliability:
#  - No global pkill. Only kills iperf3 *servers* within each target netns.
#  - Preflights a 1s probe to each UE before the long runs.
# PRB log handling:
#  - At script start, truncate /tmp/prb_log.txt *in place* (no remove/rename).
#    This preserves the gNB's open FD and captures only this run's data window.
# Ownership:
#  - All files under results/ are owned by the local user even under sudo.
#

set -Eeuo pipefail

# ---------- defaults ----------
DN_CONTAINER="oai-ext-dn"
PORT=5201
PRB_LOG="/tmp/prb_log.txt"
PRB_FEAT="/tmp/prb_features_ai.csv"

DURATION=600          # total scenario seconds
ATTACK_START=60       # when UE3 DoS begins
RECOVERY_SEC=60       # tail with only honest UEs transmitting

HONEST_RATE_Mbps=10   # UE1/UE2 per-UE rate
HONEST_PARALLEL=1

MAL_RATE_Mbps=150     # UE3 DoS peak (default increased to 150 Mb/s)
MAL_PARALLEL=1
TON=1                 # seconds ON
TOFF=3                # seconds OFF

RESULTS_BASE="./results"

UE1_IP=""
UE2_IP=""
UE3_IP=""

# Trickle Traffic
TRICKLE=0
# Default trickle rate (kbps). Tune by exporting TRICKLE_KBPS or edit here.
: "${TRICKLE_KBPS:=64}"

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

Infra:
  --dn <name>             DN container (default: $DN_CONTAINER)
  --port <p>              iperf3 port (default: $PORT)
  --prb-log <path>        PRB log path (default: $PRB_LOG)
  --ue1-ip <ip>           UE1 IPv4 (auto-discover if omitted)
  --ue2-ip <ip>           UE2 IPv4 (auto-discover if omitted)
  --ue3-ip <ip>           UE3 IPv4 (auto-discover if omitted)

Timing:
  --duration <s>          total duration (default: $DURATION)
  --attack-start <s>      DoS start time (default: $ATTACK_START)
  --recovery <s>          recovery tail (default: $RECOVERY_SEC)
  --ton <s>               attacker ON seconds (default: $TON)
  --toff <s>              attacker OFF seconds (default: $TOFF)

Rates:
  --honest-rate <Mbps>    UE1/UE2 rate each (default: $HONEST_RATE_Mbps)
  --honest-parallel <n>   iperf -P for UE1/UE2 (default: $HONEST_PARALLEL)
  --mal-rate <Mbps>       UE3 DoS peak (default: $MAL_RATE_Mbps)
  --mal-parallel <n>      iperf -P for UE3 (default: $MAL_PARALLEL)
  --trickle               Send minimal traffic during Off bursts (default: 0 Mbps)
  --pulse                 Send a traffic spike during Off bursts (requires: toff divisible by 3)
  
Output:
  --results <dir>         results base (default: $RESULTS_BASE)

Examples:
  sudo bash $0
  sudo bash $0 --ue1-ip 12.1.1.2 --ue2-ip 12.1.1.3 --ue3-ip 12.1.1.4 --ton 1 --toff 3 --mal-rate 150
EOF
}

# ---------- arg parse ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dn)               DN_CONTAINER="$2"; shift 2;;
    --port)             PORT="$2"; shift 2;;
    --prb-log)          PRB_LOG="$2"; shift 2;;
    --ue1-ip)           UE1_IP="$2"; shift 2;;
    --ue2-ip)           UE2_IP="$2"; shift 2;;
    --ue3-ip)           UE3_IP="$2"; shift 2;;
    --duration)         DURATION="$2"; shift 2;;
    --attack-start)     ATTACK_START="$2"; shift 2;;
    --recovery)         RECOVERY_SEC="$2"; shift 2;;
    --ton)              TON="$2"; shift 2;;
    --toff)             TOFF="$2"; shift 2;;
    --honest-rate)      HONEST_RATE_Mbps="$2"; shift 2;;
    --honest-parallel)  HONEST_PARALLEL="$2"; shift 2;;
    --mal-rate)         MAL_RATE_Mbps="$2"; shift 2;;
    --mal-parallel)     MAL_PARALLEL="$2"; shift 2;;
    --results)          RESULTS_BASE="$2"; shift 2;;
    --trickle)          TRICKLE=1;    shift 1 ;;
    --pulse)            PULSE=1;      shift 1 ;;
    -h|--help)          usage; exit 0;;
    *) echo "ERROR: Unknown argument: $1"; usage; exit 2;;
  esac
done

echo "TON=${TON} TOFF=${TOFF} MAL_RATE=${MAL_RATE_Mbps} TRICKLE=${TRICKLE} HONEST=${HONEST_RATE_Mbps} PORT=${PORT}"

# ---------- helpers ----------
off_bitrate() {
   if [[ "${TRICKLE}" -eq 1 ]]; then
     # iperf3 expects units; use K for kilobits per second
     echo "${TRICKLE_KBPS}K"
   else
     echo "0"
   fi
}

discover_ip() {
  ip -n "$1" -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}

# Pre-create file owned by local user so redirects don't create root-owned outputs
precreate() {
  local f="$1"
  sudo -u "${RUN_USER}" bash -lc "umask 002; install -D -m 0664 /dev/null \"$f\""
}

# Kill only iperf3 *server* PIDs inside a given netns (no global pkill).
kill_ns_iperf_servers() {
  local ns="$1"
  local p
  for p in $(ip netns pids "$ns"); do
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE '(^| )iperf3( |$)'; then
      if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q ' -s '; then
        kill -9 "$p" 2>/dev/null || true
      fi
    fi
  done
}

# ---------- discovery ----------
[[ -z "$UE1_IP" ]] && UE1_IP=$(discover_ip ue1)
[[ -z "$UE2_IP" ]] && UE2_IP=$(discover_ip ue2)
[[ -z "$UE3_IP" ]] && UE3_IP=$(discover_ip ue3)

if [[ -z "$UE1_IP" || -z "$UE2_IP" || -z "$UE3_IP" ]]; then
  echo "ERROR: Could not auto-discover ue1/ue2/ue3 IPs. Pass --ue1-ip/--ue2-ip/--ue3-ip."
  exit 1
fi

# Validate timing
for v in "$DURATION" "$ATTACK_START" "$RECOVERY_SEC" "$TON" "$TOFF"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "ERROR: timing values must be integers"; exit 1; }
done
(( DURATION > 0 )) || { echo "ERROR: duration must be > 0"; exit 1; }
(( ATTACK_START < DURATION )) || { echo "ERROR: attack-start must be < duration"; exit 1; }
(( RECOVERY_SEC >= 0 && RECOVERY_SEC < DURATION )) || { echo "ERROR: recovery must be in [0, duration)"; exit 1; }
ATTACK_STOP=$(( DURATION - RECOVERY_SEC ))
(( ATTACK_START < ATTACK_STOP )) || { echo "ERROR: attack window is empty"; exit 1; }
ATTACK_WINDOW=$(( ATTACK_STOP - ATTACK_START ))

# Validate --pulse constraints: Toff must be divisible by 3 when pulse enabled
if [[ "${PULSE:-0}" -eq 1 ]]; then
  if ! [[ "${TOFF}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --pulse requires integer --toff"; exit 2
  fi
  if (( TOFF % 3 != 0 )); then
    echo "ERROR: --pulse requires --toff to be divisible by 3 (got ${TOFF})"; exit 2
  fi
fi

# ---------- results directory with local ownership ----------
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_DIR="${RESULTS_BASE}/run-$(date +%Y%m%d-%H%M%S)"
install -d -m 2775 -o "$RUN_USER" -g "$RUN_GROUP" "$RUN_DIR"

# ---------- CLI run log ----------
LOG_FILE="${RUN_DIR}/run-cli.log"

# Reconstruct a shell-like prompt line with the exact invocation.
# Prefer the real sudo command if present; otherwise quote $0 "$@" safely.
_prompt_user="${SUDO_USER:-$USER}"
_prompt_host="$(hostname -s 2>/dev/null || hostname)"
_prompt_pwd="$(pwd)"
if [[ -n "${SUDO_COMMAND:-}" ]]; then
  _cmd="$SUDO_COMMAND"
else
  # printf %q preserves quoting for exact re-run
  _cmd="$(printf '%q ' "$0" "$@")"
fi
printf '%s@%s:%s$ %s\n' "$_prompt_user" "$_prompt_host" "$_prompt_pwd" "$_cmd" | tee "$LOG_FILE" >/dev/null

# From here on, capture EVERYTHING (stdout+stderr) to the log and console
exec > >(tee -a "$LOG_FILE") 2>&1

# Banner with timestamps + exit status
START_TS=$(date +%s)
echo "==== Run started $(date -Is) ===="
trap 'rc=$?; echo "==== Run finished $(date -Is); elapsed=$(( $(date +%s)-START_TS ))s; exit=$rc ====";' EXIT

# Always ensure final ownership; stop servers on exit
cleanup() {
  [[ -f "$RUN_DIR/ue1.pid" ]] && kill "$(cat "$RUN_DIR/ue1.pid")" 2>/dev/null || true
  [[ -f "$RUN_DIR/ue2.pid" ]] && kill "$(cat "$RUN_DIR/ue2.pid")" 2>/dev/null || true
  [[ -f "$RUN_DIR/ue3.pid" ]] && kill "$(cat "$RUN_DIR/ue3.pid")" 2>/dev/null || true
  chown -R "$RUN_USER:$RUN_GROUP" "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "UE1_IP=${UE1_IP}"
echo "UE2_IP=${UE2_IP}"
echo "UE3_IP=${UE3_IP}"
echo "DN_CONTAINER=${DN_CONTAINER}"
echo "Duration=${DURATION}s  Attack: ${ATTACK_START}s→${ATTACK_STOP}s  Recovery=${RECOVERY_SEC}s"
echo "Honest=${HONEST_RATE_Mbps} Mb/s (P=${HONEST_PARALLEL})  DoS=${MAL_RATE_Mbps} Mb/s (Ton=${TON}, Toff=${TOFF}, P=${MAL_PARALLEL})"
echo "Results: ${RUN_DIR}"

# ---------- Step 0: truncate PRB log in place (no delete/rename) ----------
# Only truncate if it exists (avoids replacing with a new inode).
if [[ -e "$PRB_LOG" ]]; then
  : > "$PRB_LOG"
fi

# ---------- start iperf3 servers, bound to UE IPs ----------
kill_ns_iperf_servers ue1
kill_ns_iperf_servers ue2
kill_ns_iperf_servers ue3

precreate "${RUN_DIR}/ue1_server.log"
ip netns exec ue1 iperf3 -s -B "${UE1_IP}" -p "${PORT}" -i 1 > "${RUN_DIR}/ue1_server.log" 2>&1 &
echo $! > "${RUN_DIR}/ue1.pid"

precreate "${RUN_DIR}/ue2_server.log"
ip netns exec ue2 iperf3 -s -B "${UE2_IP}" -p "${PORT}" -i 1 > "${RUN_DIR}/ue2_server.log" 2>&1 &
echo $! > "${RUN_DIR}/ue2.pid"

precreate "${RUN_DIR}/ue3_server.log"
ip netns exec ue3 iperf3 -s -B "${UE3_IP}" -p "${PORT}" -i 1 > "${RUN_DIR}/ue3_server.log" 2>&1 &
echo $! > "${RUN_DIR}/ue3.pid"

sleep 1

# Ensure UE3 is actually listening before DN preflight (stabilizes sweep races)
for _ in 1 2 3 4 5; do
  if ip netns exec ue3 bash -lc "ss -ltn '( sport = :${PORT} )' | grep -q LISTEN"; then
    break
  fi
  sleep 0.2
done

# ---------- preflight probes (1s UDP@1M) ----------
for n in 1 2 3; do
  UE_IP_VAR="UE${n}_IP"; UE_IP="${!UE_IP_VAR}"
  precreate "${RUN_DIR}/preflight_ue${n}.json"
  precreate "${RUN_DIR}/preflight_ue${n}.err"
  if ! docker exec "${DN_CONTAINER}" bash -lc "iperf3 -c ${UE_IP} -p ${PORT} -t 1 -u -b 1M -J" \
        > "${RUN_DIR}/preflight_ue${n}.json" 2> "${RUN_DIR}/preflight_ue${n}.err"; then
     if [[ "$n" -eq 3 ]]; then
       sleep 1
       docker exec "${DN_CONTAINER}" bash -lc "iperf3 -c ${UE_IP} -p ${PORT} -t 1 -u -b 1M -J" \
         > "${RUN_DIR}/preflight_ue${n}.json" 2> "${RUN_DIR}/preflight_ue${n}.err" || {
           echo "ERROR: Preflight to UE${n} (${UE_IP}:${PORT}) failed from ${DN_CONTAINER}"
           exit 1
         }
     else
       echo "ERROR: Preflight to UE${n} (${UE_IP}:${PORT}) failed from ${DN_CONTAINER}"
       exit 1
     fi
   fi
done

# ---[ NEW: align PRB log to baseline start ]-----------------------------------
# Create a small runtime log that tells post-processing when the baseline starts.
RUNTIME_LOG="${RUN_DIR}/runtime.log"
TTI_MS="${TTI_MS:-0.5}"              # NR µ=1 → 0.5 ms per TTI (30 kHz SCS)
BASELINE_EPOCH="$(date +%s)"         # wall-clock time at baseline start

# Truncate the gNB PRB log *in place* (no unlink), so the gNB keeps writing.
# This drops any preflight lines and makes the very next TTI the first for this run.
: > "${PRB_LOG}"

# Record mapping for post-processing (no writes to the gNB file itself).
{
  echo "baseline_start_epoch=${BASELINE_EPOCH}"
  echo "tti_ms=${TTI_MS}"
  echo "prb_log=${PRB_LOG}"
} > "${RUNTIME_LOG}"

# Keep files owned by the invoking user even under sudo
chown "$(id -u -n)":"$(id -g -n)" "${RUNTIME_LOG}" 2>/dev/null || true
# -------------------------------------------------------------------------------

# ---------- Step 1: honest UE1/UE2 for full duration ----------
precreate "${RUN_DIR}/UE1_honest.json"; precreate "${RUN_DIR}/UE1_honest.err"
docker exec "${DN_CONTAINER}" bash -lc "iperf3 -J -c ${UE1_IP} -p ${PORT} -i 1 -t ${DURATION} -u -b ${HONEST_RATE_Mbps}M -P ${HONEST_PARALLEL}" \
  > "${RUN_DIR}/UE1_honest.json" 2> "${RUN_DIR}/UE1_honest.err" &
C1=$!

precreate "${RUN_DIR}/UE2_honest.json"; precreate "${RUN_DIR}/UE2_honest.err"
docker exec "${DN_CONTAINER}" bash -lc "iperf3 -J -c ${UE2_IP} -p ${PORT} -i 1 -t ${DURATION} -u -b ${HONEST_RATE_Mbps}M -P ${HONEST_PARALLEL}" \
  > "${RUN_DIR}/UE2_honest.json" 2> "${RUN_DIR}/UE2_honest.err" &
C2=$!

# ---------- Steps 2 & 3: DoS bursts from ATTACK_START until ATTACK_STOP ----------
run_attack() {
  local window=${ATTACK_WINDOW}
  local elapsed=0
  sleep "${ATTACK_START}"
  local cycle=$(( TON + TOFF ))
  local idx=0
  while (( elapsed < window )); do
    # ON burst (truncate if needed)
    local on=${TON}
    if (( elapsed + on > window )); then on=$(( window - elapsed )); fi
    local tag
    printf -v tag "UE3_burst%03d" "${idx}"
    precreate "${RUN_DIR}/${tag}.json"; precreate "${RUN_DIR}/${tag}.err"
    docker exec "${DN_CONTAINER}" bash -lc "iperf3 -J -c ${UE3_IP} -p ${PORT} -i 1 -t ${on} -u -b ${MAL_RATE_Mbps}M -P ${MAL_PARALLEL}" \
      > "${RUN_DIR}/${tag}.json" 2> "${RUN_DIR}/${tag}.err" || true
    elapsed=$(( elapsed + on ))
    if (( elapsed >= window )); then break; fi
    
    # OFF gap (truncate if needed)
    local off=${TOFF}
    if (( elapsed + off > window )); then off=$(( window - elapsed )); fi

    # OFF: support --pulse which splits OFF into 3s windows: 2s rest/trickle + 1s pulse at 0.5*mal_rate
    if [[ "${PULSE:-0}" -eq 1 ]]; then
        # off must be divisible by 3 (validated earlier). iterate over 3s windows
        local chunks=$(( off / 3 ))
        for ((c=0;c<chunks;c++)); do
            # 2s rest or trickle
            if [[ "${TRICKLE:-0}" -eq 1 ]]; then
                docker exec "${DN_CONTAINER}" bash -lc \
                "iperf3 -u -t 2 -b ${TRICKLE_KBPS:-64}K -c ${UE3_IP} -p ${PORT} -i 1 -P ${MAL_PARALLEL}" \
                >/dev/null 2>&1 || true
            else
                sleep 2
            fi
            # 1s pulse at half mal rate
            local pulse_rate
            pulse_rate=$(awk "BEGIN{printf \"%s\", ${MAL_RATE_Mbps}/2}")
            docker exec "${DN_CONTAINER}" bash -lc \
            "iperf3 -u -t 1 -b ${pulse_rate}M -c ${UE3_IP} -p ${PORT} -i 1 -P ${MAL_PARALLEL}" \
            >/dev/null 2>&1 || true
        done
    else
        if [[ "${TRICKLE:-0}" -eq 1 ]]; then
            docker exec "${DN_CONTAINER}" bash -lc \
            "iperf3 -u -t ${off} -b ${TRICKLE_KBPS:-64}K -c ${UE3_IP} -p ${PORT} -i 1 -P ${MAL_PARALLEL}" \
            >/dev/null 2>&1 || true
        else
            sleep "${off}"
        fi
    fi

    elapsed=$(( elapsed + off ))
    idx=$(( idx + 1 ))
  done
}
run_attack &
CA=$!

# ---------- wait for honest + attack ----------
wait "$C1"
wait "$C2"
wait "$CA"

# ---------- Step 4: Post-process Jain’s ----------
# --- PRB-level post-processing (TTI granularity) ---
if [[ -f "${PRB_LOG}" ]]; then
  echo "→ parsing PRB log and writing PRB allocations + Jain’s (TTI) ..."

  # Copy scheduler log to output directory
  sudo cp /tmp/prb_log.txt "$RUN_DIR/"
  sudo cp /tmp/prb_features_ai.csv "$RUN_DIR/"
  cp parse_prb_log_tti.py "$RUN_DIR/"
  cp prb_plots_from_evidence.py "$RUN_DIR/"
  cp oran_build_feature_set_attack.py "$RUN_DIR/"

  pushd "$RUN_DIR" >/dev/null || exit 1
#  sudo -u "$SUDO_USER" python3 parse_prb_log_tti.py --duration 240 --attack-start 60 --attack-end 210
#  sudo -u "$SUDO_USER" python3 prb_plots_from_evidence.py --csv ./prb_tti_evidence.csv --outdir ./figures \
#    --smooth-tti 100 --duration 240 --attack-start 60 --attack-end 210 --marker-offset-tti -11000
  sudo -u "$SUDO_USER" python3 oran_build_feature_set_attack.py --features prb_features_ai.csv --log prb_log.txt --out prb_tti_evidence_ai.csv --capacity 106 --tti-ms 0.0005
  popd >/dev/null
else
  echo "⚠️  PRB log not found at ${PRB_LOG}; skipping PRB-level outputs."
fi

# Final ownership pass
chown -R "$RUN_USER:$RUN_GROUP" "$RUN_DIR" 2>/dev/null || true
echo "Done: Steps 1–4 complete. Results in ${RUN_DIR}"

