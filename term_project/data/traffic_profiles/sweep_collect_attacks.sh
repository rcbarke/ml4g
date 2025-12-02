#!/usr/bin/env bash
# sweep_collect_attacks.sh
# Grid sweep driver to collect 30-minute attack runs for TCN+SVD training.
# - Calls the existing oai_prb_dos.sh wrapper repeatedly with different Ton/Toff/mal-rate/trickle/honest-rate settings.
# - Each run is 600s (10 minutes).
# - Copies the run results into a central sweep results folder and writes a run manifest.
#
# NOTE: Adjust OAI_SCRIPT path if your driver script is elsewhere.
#       This script expects oai_prb_dos.sh to create its own run directory (as the original script does).
#       If your base script uses different flag names, change the passthrough variables below.

set -euo pipefail
IFS=$'\n\t'

# ---------- Configuration ----------
OAI_SCRIPT="./oai_prb_dos.sh"          # path to base attack script (change if needed)
RESULTS_ROOT="./sweep_results"         # where sweep results will be aggregated
RUN_DURATION=600                       # seconds (10 minutes)
RUN_MINUTES=$(echo "$RUN_DURATION/60" | bc -l)  # unit conversion
SLEEP_BETWEEN_RUNS=10                  # seconds pause between runs
IPERF_MIN_T=0.8                        # iperf3 minimum -t in seconds
START_AT="${START_AT:-1}"	       # Resume control: start at given 1-based run index (export START_AT)

# Grid: Ton (s), Toff (s), mal_rates (Mbps), trickle options, honest rates
# Ensure TON values are >= IPERF_MIN_T
TON_LIST=(1 2)                       # seconds (all >= 0.8) (required as integer)
TOFF_LIST=(6 9)                      # seconds (required as integer)
MAL_RATE_LIST=(180 240)              # Mbps -- attacker offered rate
TRICKLE_OPTIONS=(0 1)                # 0=no trickle, 1=trickle enabled

# Honest (benign) offered rates to sweep during ON 
HONEST_RATE_LIST=(15 30)             # Mbps values for --honest-rate flag

# Additional passthrough args you want to always include for the base script:
COMMON_ARGS=( --duration "$RUN_DURATION" --pulse )  # base script's --duration, will be overridden if it sets own run-dir logic

# How many repeats of each configuration
REPEATS=1

# SSH user / IPs: leave empty to allow base script dynamic IP discovery (recommended)
SSH_USER=""    # if needed: "oai"
UE1_IP=""      # if you want to supply static IPs (leave blank for auto-discover)
UE2_IP=""
UE3_IP=""

# sanity checks
if [[ ! -x "$OAI_SCRIPT" ]]; then
  echo "[ERROR] base script not found/executable at: $OAI_SCRIPT"
  exit 1
fi

mkdir -p "$RESULTS_ROOT"
MANIFEST="$RESULTS_ROOT/sweep_manifest_$(date +%Y%m%d-%H%M%S).csv"
echo "run_id,ton_s,toff_s,mal_rate_mbps,trickle,honest_rate_mbps,repeat,run_dir,started_at,ended_at,notes" > "$MANIFEST"

# ---------- helper functions ----------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
uid_now() { date +"%Y%m%d-%H%M%S-%3N"; }

# copy run artifacts: attempt to detect base script's created run folder (heuristic)
copy_run_artifacts() {
  local tmp_prefix="$1"   # string that base script prints for run dir, or leave empty
  local dest="$2"
  mkdir -p "$dest"
  # Heuristic: base script prints a run dir in stdout like "Run directory: ./results/run-YYYYMMDD-HHMMSS"
  # We will scan recent directories under ./results (if present) for most-recent modification time and copy it.
  local candidate=""
  if [[ -d "./results" ]]; then
    candidate=$(ls -1t ./results | head -n1)
    if [[ -n "$candidate" ]]; then
      candidate="./results/$candidate"
      # make sure candidate is a directory and not the entire repo
      if [[ -d "$candidate" ]]; then
        cp -a "$candidate" "$dest/"
        echo "$candidate"
        return 0
      fi
    fi
  fi
  # Fallback: copy /tmp/prb_log.txt & /tmp/prb_features_ai.csv if they exist (some runs rely on tmp files)
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

# ---------- sweep loop ----------
run_counter=0
for repeat in $(seq 1 $REPEATS); do
  for ton in "${TON_LIST[@]}"; do
    # Validate TON >= IPERF_MIN_T
    if ! awk -v t="$ton" -v m="$IPERF_MIN_T" 'BEGIN{exit !(t+0 >= m)}'; then
      echo "[WARN] TON ${ton}s < iperf minimum ${IPERF_MIN_T}s, skipping"
      continue
    fi

    for toff in "${TOFF_LIST[@]}"; do
      for mal in "${MAL_RATE_LIST[@]}"; do
        for trickle in "${TRICKLE_OPTIONS[@]}"; do
            for honest in "${HONEST_RATE_LIST[@]}"; do
              run_counter=$((run_counter+1))
              run_tag="sweep_$(uid_now)_r${repeat}_tON${ton}tOFF${toff}_mal${mal}Mbps_trick${trickle}_honest${honest}Mbps"
              if [[ "$run_counter" -lt "$START_AT" ]]; then
                echo "[SKIP] run_index=${run_counter} < START_AT=${START_AT} :: $run_tag"
                continue
              fi
              echo "------------------------------------------------------------"
              echo "[${run_counter}] Starting run: $run_tag"
              echo "  TON=${ton}s  TOFF=${toff}s  MAL_RATE=${mal}Mbps  TRICKLE=${trickle}  HONEST_RATE=${honest}Mbps"
              echo "  Duration: ${RUN_DURATION}s (${RUN_MINUTES} minutes)"
              started_at="$(timestamp)"

              # Build command-line for base script.
              # The exact option names below are guess/typical: change them if your base script uses different flags.
              args=()
              args+=( "$OAI_SCRIPT" )
              # Ton / Toff in seconds
              args+=( --ton "$ton" --toff "$toff" )
              # attacker offered rate
              args+=( --mal-rate "$mal" )
              # trickle: pass --trickle when enabled
              if [[ "$trickle" -eq 1 ]]; then
                args+=( --trickle )   # if base script expects --trickle or --drizzle replace as needed
              fi

              # honest-rate (pass-through, base script must accept --honest-rate in Mbps)
              args+=( --honest-rate "$honest" )

              # pass duration to base driver (some drivers already require duration; this is safe)
              args+=( --duration "$RUN_DURATION" )

              # optionally provide ue IPs or ssh-user
              if [[ -n "$SSH_USER" ]]; then
                args+=( --ssh-user "$SSH_USER" )
              fi
              if [[ -n "$UE1_IP" ]]; then args+=( --ue1 "$UE1_IP" ); fi
              if [[ -n "$UE2_IP" ]]; then args+=( --ue2 "$UE2_IP" ); fi
              if [[ -n "$UE3_IP" ]]; then args+=( --ue3 "$UE3_IP" ); fi

              # print & run
              echo "COMMAND: ${args[*]}"
              # run and stream logs to sweep results file
              RUN_LOG="$RESULTS_ROOT/${run_tag}.log"
              # Run in foreground; interruptible by user (CTRL-C)
              set +e
              "${args[@]}" 2>&1 | tee "$RUN_LOG"
              rc=$?
              set -e
              ended_at="$(timestamp)"

              # try to collect artifacts (heuristic)
              dest_dir="$RESULTS_ROOT/$run_tag"
              mkdir -p "$dest_dir"
              note=""
              if [[ $rc -ne 0 ]]; then
                note="base_script_exit=$rc"
                echo "[WARN] base script exited with code $rc (see $RUN_LOG)"
              fi

              copied=$(copy_run_artifacts "$run_tag" "$dest_dir")
              if [[ -n "$copied" ]]; then
                echo "[INFO] copied run artifacts into $dest_dir (source: $copied)"
              else
                echo "[WARN] could not find run dir; copied log only."
              fi
              # move the run log into dest
              mv "$RUN_LOG" "$dest_dir/"

              # record manifest entry
              echo "${run_tag},${ton},${toff},${mal},${trickle},${honest},${repeat},${dest_dir},${started_at},${ended_at},${note}" >> "$MANIFEST"

              echo "[INFO] run completed: $run_tag  (saved to $dest_dir)"
              echo "Sleeping for ${SLEEP_BETWEEN_RUNS}s before next run..."
              sleep "$SLEEP_BETWEEN_RUNS"

          done # honest
        done # trickle
      done # mal
    done # toff
  done # ton
done # repeat

echo "Sweep complete. Manifest: $MANIFEST"

