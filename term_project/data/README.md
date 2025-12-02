# PRB-Graph (ML4G) Dataset — README

## 1. Purpose and Scope

This directory contains the **TTI-Trust / PRB-Graph** dataset used for the CPSC 8810 (ML4G) term project.

The goal is **not** to provide a production-quality URLLC dataset, but to support an **offline GNN MVP** for:

> **UE-level PRB starvation detection from scheduler logs**  
> using a compact GraphSAGE classifier on UE-contention graphs built from windowed PF evidence.

This dataset is derived from an **OpenAirInterface (OAI) + iperf** single-cell, three-UE setup and is known to have timing issues. It is intentionally preserved here as a **teaching / prototyping dataset** to:

- demonstrate how to turn scheduler logs into a graph-ML problem, and  
- document the modeling challenges that arise when **wall-time is not slot-time**. :contentReference[oaicite:0]{index=0}  

A future “clean” dataset will be regenerated on **NVIDIA Aerial / cuMAC on DGX Spark** where 0.5 ms slot timing is enforced by GPU L1/L2, but that data is *not* included here.

---

## 2. Data Origin and High-Level Description

### 2.1 Source environment

- **RAN stack:** OpenAirInterface 5G gNB in RFSim-style configuration
- **Traffic generator:** iperf-based burst traffic for the “attacker”, stochastic traffic for benign UEs
- **Scenario:** single cell, ≈3 UEs, proportional-fair scheduling with URLLC-style bursts
- **Logging:** per-TTI PF ledger written at nominal 0.5 ms intervals, including:
  - PRB grants per UE
  - cumulative PRB allocation
  - fairness statistics (e.g., Jain’s J)
  - basic scheduler evidence (MCS/CQI, HARQ utilization, where available)

### 2.2 Files

At a minimum, the dataset includes:

- `prb_tti_evidence_ai_attack.csv`  
- `prb_tti_evidence_ai_benign.csv`  

plus derived artifacts produced by the **TTI-Trust** preprocessing pipeline:

- `win_shards/*.npz`  
  - windowed tensors with per-TTI features (`xb_seq`) and auxiliary features (`xb_aux`)
- `*_meta.parquet`  
  - metadata per window: `run_id`, `phase`, `window_start`, `label`, etc.

Each row in the raw CSVs corresponds to a **single TTI** with per-UE PRB usage and fairness summaries. The windowing scripts group these into **fixed-length sliding windows** (e.g., `W = 100` TTIs) with labels indicating whether that window exhibits **PF-based PRB starvation** under a pre-defined predicate. 

---

## 3. Intended Graph-ML Task

The ML4G project formulates an **applications-type** GNN task: use PyTorch Geometric to detect PRB starvation in O-RAN from scheduler logs.

### 3.1 Graph construction (per sliding window)

For each TTI window (e.g., 100 TTIs), we build one graph:

- **Nodes (UE–window pairs):**  
  One node per UE that appears in the window.

- **Edges (UE contention within the window):**
  - Undirected edge between UE *i* and UE *j* if they are *co-scheduled* on ≥1 TTI in that window.
  - Optional edge attributes capturing “how hard” they contend, e.g.:
    - `overlap_frac`: fraction of TTIs where both have non-zero PRBs
    - `co_scheduled_slots`: number of TTIs with both active
    - `prb_overlap_intensity`: mean of `min(PRB_i, PRB_j) / C_PRB` on co-active TTIs

This is a simplified, **offline-only** slice of the broader PRB-Graph proposal, which also includes temporal chains and a future near-RT head. :contentReference[oaicite:5]{index=5}  

### 3.2 Node features

For each UE in a window we derive a compact feature vector encoding how that UE was treated by the scheduler:

- **PRB usage statistics**
  - mean PRB share: `mean(PRB_i(t) / C_PRB)`
  - min / max PRB share over the window
  - standard deviation of PRB share

- **PF / fairness proxies**
  - rolling PF surrogate (EWMA) at end of window
  - Δ PF surrogate over the window

- **Temporal starvation shape**
  - fraction of TTIs with `PRB_i(t) == 0` (hard starvation)
  - longest consecutive run of `PRB_i(t) == 0` (run-length)

- **Optional extras (if present in shard):**
  - mean CQI / MCS over the window
  - BLER / HARQ utilization summaries

These are derived from the same per-TTI ledger fields used in the original TTI-Trust classifier.

### 3.3 Labels

We use **graph-level binary labels**:

- `y = 1` if the window is “attack / starved” under the PF-based predicate used in TTI-Trust.
- `y = 0` otherwise.

Node-level labels (e.g., which UE is starved) can be derived but are not required for the MVP.

### 3.4 MVP model

The reference GNN is a small **GraphSAGE → global pooling → MLP** classifier:

1. Two SAGEConv layers over the UE-contention graph
2. Global mean pooling over nodes
3. 2-layer MLP → binary logit (`attack` vs `benign`)

We train with **grouped K-fold CV by `run_id`** so that windows from the same simulated run do not leak between train and validation splits. :contentReference[oaicite:6]{index=6}  

---

## 4. Known Limitations and Caveats

This dataset is *explicitly* labeled as **noisy and timing-broken**. It is suitable for **class projects and prototyping**, not for claiming production-grade URLLC results.

### 4.1 0.5 ms TTI ↔ wall-time mismatch

- The OAI + iperf stack runs on a **general-purpose x86 OS** with:
  - multi-second traffic warm-ups, and
  - OS scheduling / NUMA / cache jitter.
- As documented in the milestone and follow-up work, these effects **stretch and compress T_ON/T_OFF intervals**, corrupting the intended 0.5 ms TTI timing grid.   
- Consequence:
  - Starvation labels and fairness metrics (e.g., Jain’s J) are **noisy**.
  - The GNN may learn artifacts of OS noise rather than pure PF dynamics.

### 4.2 Small, low-entropy graphs

- The scenario is **single-cell, 3-UE**, so each window graph has only a handful of nodes.
- Many graphs share similar structure; in the limit, GraphSAGE can behave like an MLP over per-node statistics.
- This MVP **does not stress-test message passing** the way a larger, multi-cell contention graph would.

### 4.3 Noisy edge semantics

- “Co-scheduled in the window” is defined on a time axis that is itself jittered.
- Some edges connect UEs that **only coincide due to timing drift**, not genuine PRB competition.
- Edge attributes therefore mix real contention with measurement artifacts.

### 4.4 Metrics are internal, not external

- AUROC / AUPRC / F1 computed on this dataset measure:
  - *Within this logging/jitter regime*, can the GNN separate attack vs benign?
- They **do not** yet establish:
  - Whether the same architecture would detect PRB starvation on a physically faithful Aerial/cuMAC trace with guaranteed 0.5 ms slot timing and GPU L1. 

### 4.5 Simulation ≠ digital twin

- These traces are from a CPU-bound host-OS simulator, not from a **GPU-native digital twin** (e.g., Aerial Omniverse Digital Twin, ACAR). AtlasRAN explicitly notes that host-OS simulators suffer from OS noise and scale limits that break Markov assumptions for RL and timing-sensitive control.
- The ML4G project treats this dataset as a **stepping stone**; the long-term plan is to regenerate PF ledgers on DGX Spark + Aerial where slot-time determinism holds by construction.   

---

## 5. Appropriate Uses

You **can** use this dataset for:

- Learning how to:
  - parse per-TTI scheduler logs,
  - window them into fixed horizons,
  - build UE-contention graphs in PyG, and
  - train/evaluate a GraphSAGE classifier with grouped CV.
- Performing **ablation studies** on:
  - node vs edge features,
  - graph vs non-graph baselines (e.g., MLP/GRU on windowed features),
  - sensitivity to window length or contention threshold.
- Writing up a **course project report / blog post** that:
  - clearly states the limitations,
  - focuses on methodology and analysis rather than headline accuracy. 

You **should not** use this dataset for:

- Publication-grade URLLC performance claims,
- Benchmarking near-RT / xApp algorithms under strict latency guarantees,
- Security claims about PF starvation attacks in production RANs.

---

## 6. Future Data: Aerial / DGX Spark Path

The long-term research path (outside this course) is to:

1. **Regenerate PRB traces** on **NVIDIA Aerial cuPHY/cuMAC** running on DGX Spark / GH200, with:
   - GPU-accelerated L1 and MAC,
   - 0.5 ms slot timing enforced at the hardware level,
   - per-TTI ledgers via Aerial’s data lake.   
2. **Keep the CSV schema identical** so that:
   - the **graph construction and GNN code in this repo are drop-in**.
3. Re-train the same GraphSAGE model on the new traces and re-evaluate:
   - That becomes the “PRB-Graph on true URLLC-grade traces” paper / follow-up.

This README is intentionally explicit so that anyone who encounters this dataset in the future understands **both its value (for teaching and prototyping)** and **its limitations (for scientific claims).**

---

## 7. Citation

If you reference this dataset or the surrounding methodology, please cite:

- **PRB-Graph proposal:**  
  *“PRB-Graph: A Spatio-Temporal GNN to Reconstruct PF Dynamics and Detect PRB Starvation from Scheduler Logs.”*

- **AtlasRAN ecosystem survey:**  
  *“AtlasRAN: The O-RAN and AI-RAN Compass.”* 

- **Six Times to Spare (LDPC + DGX Spark):**  
  *“Six Times to Spare: LDPC Acceleration on DGX Spark for AI-Native RAN.”*   

And, where relevant, the ML4G project description. 

