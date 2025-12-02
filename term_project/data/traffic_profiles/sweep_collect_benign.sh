#!/usr/bin/env bash
# sweep_collect_benign.sh (resumable + retries)
# Benign eMBB sweep for AE (unsupervised) + TCN/SVD (supervised).
# - Uses oai_embb.sh; NO --seed passed; excludes default P0/P1/P2/P3.
# - Supports resuming from a specific run index: export START_AT=N
# - Retries failed runs up to MAX_RETRIES with backoff.

set -euo pipefail
IFS=$'\n\t'

# ---------- Config ----------
EMBB_SCRIPT="./oai_embb.sh"
RESULTS_ROOT="./sweep_benign_results"
RUN_DURATION=600                # 10 min
SLEEP_BETWEEN_RUNS=10
IPERF_MIN_T=0.8                 # iperf3 -t lower bound (slice >= 0.8s)

# Occupancy profiles (sum to 1.0) — NOT the default {0.05,0.25,0.35,0.35}
PSETS=(
  "0.10,0.50,0.30,0.10"  # solo-heavy
  "0.02,0.20,0.43,0.35"  # multi-UE heavy
  "0.20,0.40,0.30,0.10"  # low-activity
)

# Rate bands (min,max) in Mbps
RATE_BANDS=(
  "5,15"
  "10,25"
  "15,30"
)

# Slice lengths (seconds) — must be >= 0.8s
SLICE_LIST=(3 5 10)

# Repeats instead of --seed
REPEATS=4

# Resilience knobs
START_AT="${START_AT:-1}"       # resume index (1-based)
MAX_RETRIES="${MAX_RETRIES:-2}" # per-run retries on nonzero exit
BACKOFF_BASE="${BACKOFF_BASE:-5}" # seconds; backoff = BASE * 2^(attempt-1)

# Optional network overrides (usually blank; let oai_embb discover UEs)
SSH_USER="${SSH_USER:-}"
UE1_IP="${UE1_IP:-}"
UE2_IP="${UE2_IP:-}"
UE3_IP="${UE3_IP:-}"

# ---------- Sanity ----------
if [[ ! -x "$EMBB_SCRIPT" ]]; then
  echo "[ERROR] benign script not found/executable at: $EMBB_SCRIPT"
  exit 2
fi
mkdir -p "$RESULTS_ROOT"
MANIFEST="$RESULTS_ROOT/benign_manifest_$(date +%Y%m%d-%H%M%S).csv"
echo "run_index,run_id,repeat_idx,p0,p1,p2,p3,min_mbps,max_mbps,slice_s,duration_s,run_dir,started_at,ended_at,status,notes" > "$MANIFEST"

# ---------- Helpers ----------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
uid_now() { date +"%Y%m%d-%H%M%S-%3N"; }

copy_run_artifacts() {
  local dest="$1"
  mkdir -p "$dest"
  if [[ -d "./results" ]]; then
    local latest
    latest=$(ls -1t ./results | head -n1 || true)
    if [[ -n "${latest:-}" && -d "./results/$latest" ]]; then
      cp -a "./results/$latest" "$dest/"
      echo "./results/$latest"
      return 0
    fi
  fi
  if [[ -e /tmp/prb_log.txt || -e /tmp/prb_features_ai.csv ]]; then
    mkdir -p "$dest/tmp_files"
    [[ -e /tmp/prb_log.txt ]] && cp /tmp/prb_log.txt "$dest/tmp_files/"
    [[ -e /tmp/prb_features_ai.csv ]] && cp /tmp/prb_features_ai.csv "$dest/tmp_files/"
    echo "/tmp snapshots"
    return 0
  fi
  echo ""
  return 1
}

run_once() {
  # args: rep p0 p1 p2 p3 min_m max_m slice run_index
  local rep="$1" p0="$2" p1="$3" p2="$4" p3="$5" min_m="$6" max_m="$7" slice="$8" idx="$9"

  local run_tag="benign_$(uid_now)_r${rep}_p${p0}-${p1}-${p2}-${p3}_band${min_m}-${max_m}_slice${slice}s"
  echo "------------------------------------------------------------"
  echo "[${idx}] Starting run: ${run_tag}"
  echo "  repeat=${rep}  p={${p0},${p1},${p2},${p3}}  band=${min_m}-${max_m} Mbps  slice=${slice}s"
  local started_at; started_at="$(timestamp)"

  local args=()
  args+=( "$EMBB_SCRIPT" )
  args+=( --duration "$RUN_DURATION" )
  args+=( --slice "$slice" )
  args+=( --min-mbps "$min_m" --max-mbps "$max_m" )
  args+=( --p0 "$p0" --p1 "$p1" --p2 "$p2" --p3 "$p3" )
  if [[ -n "$SSH_USER" ]]; then args+=( --ssh-user "$SSH_USER" ); fi
  if [[ -n "$UE1_IP" ]]; then args+=( --ue1 "$UE1_IP" ); fi
  if [[ -n "$UE2_IP" ]]; then args+=( --ue2 "$UE2_IP" ); fi
  if [[ -n "$UE3_IP" ]]; then args+=( --ue3 "$UE3_IP" ); fi

  echo "COMMAND: ${args[*]}"
  local RUN_LOG="$RESULTS_ROOT/${run_tag}.log"

  # retry loop
  local attempt=0 rc=0 status="ok" note=""
  while :; do
    attempt=$((attempt+1))
    set +e
    "${args[@]}" 2>&1 | tee "$RUN_LOG"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      status="ok"
      break
    fi
    status="retry${attempt}_fail"
    note="embb_exit=$rc"
    if [[ $attempt -ge $((MAX_RETRIES+1)) ]]; then
      echo "[ERROR] Run failed after ${MAX_RETRIES} retries (rc=$rc)"
      break
    fi
    # backoff
    local sleep_s=$(( BACKOFF_BASE << (attempt-1) ))
    echo "[WARN] Run failed (rc=$rc). Retrying in ${sleep_s}s ..."
    sleep "$sleep_s"
  done

  local ended_at; ended_at="$(timestamp)"
  local dest_dir="$RESULTS_ROOT/$run_tag"
  mkdir -p "$dest_dir"

  local copied; copied=$(copy_run_artifacts "$dest_dir")
  if [[ -n "$copied" ]]; then
    echo "[INFO] copied run artifacts into $dest_dir (source: $copied)"
  else
    echo "[WARN] could not find run dir; copied log only."
  fi
  mv "$RUN_LOG" "$dest_dir/"

  echo "${idx},${run_tag},${rep},${p0},${p1},${p2},${p3},${min_m},${max_m},${slice},${RUN_DURATION},${dest_dir},${started_at},${ended_at},${status},${note}" >> "$MANIFEST"

  echo "[INFO] run completed: $run_tag  → $dest_dir  (status=${status})"
  echo "Sleeping for ${SLEEP_BETWEEN_RUNS}s ..."
  sleep "$SLEEP_BETWEEN_RUNS"
}

# ---------- Print expected runtime ----------
total_runs=$(( REPEATS * ${#PSETS[@]} * ${#RATE_BANDS[@]} * ${#SLICE_LIST[@]} ))
total_secs=$(( total_runs*RUN_DURATION + (total_runs-1)*SLEEP_BETWEEN_RUNS ))
printf "[INFO] Planned runs: %d | Est. wall-time: ~%.2f h | START_AT=%s | MAX_RETRIES=%s\n" \
  "$total_runs" "$(echo "$total_secs/3600" | bc -l)" "$START_AT" "$MAX_RETRIES"

# ---------- Sweep (resumable) ----------
run_index=0
for rep in $(seq 1 "$REPEATS"); do
  for pset in "${PSETS[@]}"; do
    IFS=',' read -r p0 p1 p2 p3 <<< "$pset"
    ok=$(awk -v a="$p0" -v b="$p1" -v c="$p2" -v d="$p3" 'BEGIN{s=a+b+c+d; print (s>=0.999 && s<=1.001)?"OK":"BAD"}')
    [[ "$ok" != "OK" ]] && { echo "[WARN] skipping invalid p-set: $pset"; continue; }

    for band in "${RATE_BANDS[@]}"; do
      IFS=',' read -r min_m max_m <<< "$band"
      awk -v x="$min_m" -v y="$max_m" 'BEGIN{exit !(x+0>0 && y+0>x+0)}' || { echo "[WARN] skipping invalid band: $band"; continue; }

      for slice in "${SLICE_LIST[@]}"; do
        awk -v s="$slice" -v m="$IPERF_MIN_T" 'BEGIN{exit !(s+0 >= m)}' || { echo "[WARN] skipping too-small slice: $slice"; continue; }

        run_index=$((run_index+1))
        # resume gate
        if [[ "$run_index" -lt "$START_AT" ]]; then
          echo "[SKIP] run_index=${run_index} < START_AT=${START_AT}"
          continue
        fi

        run_once "$rep" "$p0" "$p1" "$p2" "$p3" "$min_m" "$max_m" "$slice" "$run_index"
      done
    done
  done
done

echo "Sweep complete. Manifest: $MANIFEST"

