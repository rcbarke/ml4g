# PRB-GraphSAGE: UE-Level Contention Graphs for PRB Starvation Detection

This repository contains the code for **PRB-Graph**, a prototype **graph neural network (GNN)** that detects PRB (Physical Resource Block) starvation in 5G/O-RAN from **per-TTI proportional-fair (PF) scheduler logs**.

The work was originally developed as part of **CPSC 8810 (ML4G) at Clemson**, and is intended as a **model architecture + data pipeline prototype only**. It is *not* tuned on the full 30 GB dataset due to known noise and timing issues in the host-OS simulator logs.

---

## High-Level Idea

We start from the existing **TTI-Trust** pipeline:

- Read per-TTI PF evidence from:
  - `prb_tti_evidence_ai_attack.csv`
  - `prb_tti_evidence_ai_benign.csv`
- Perform **phase-aware windowing** into fixed-length horizons (e.g. 64 / 240 TTIs).
- Compute **identity-agnostic features** (PF surrogates, PRB shares, fairness metrics).
- Export **window shards** (`win_shards/*.npz`) and per-window metadata (`*_meta.parquet`).

On top of this, PRB-GraphSAGE adds:

- A new **UE-level graph construction step**:
  - Nodes = UEs observed in a window.
  - Edges = UE pairs that are co-scheduled on ≥1 TTI (contention edges).
  - Node features = PRB usage / starvation / activity statistics per UE.
  - Graph label = attack vs non-attack at the window level.
- A **GNN** with global pooling + MLP head to classify windows.

This gives an **offline, slot-time-aware view of PF fairness** that can later be re-run on more accurate PF logs from NVIDIA's AI-RAN stack.

---

## Repository Structure

The following files have been consolidated into a single `prb_graphsage_gnn.ipynb` notebook within `term_project/` for convenience.

```text
.
├── preproc_tti_trust.py          # TTI-Trust preprocessing: CSV -> parquet + window shards
├── tti_trust_dataloader.py       # (Optional) Sequence-level loader for the TCN baseline
├── prb_graph_dataloader.py       # UE-level graph construction & PyG DataLoaders
├── models/
│   ├── prb_graphsage_gnn_demo.py          # PRBGraph model architecture with runnable shim dataset
│   └── prb_graphsage_gnn_full_dataset.py  # PRBGraph model architecture with first two full runs of OpenAirInterface (OAI) benign + attack data
├── train_prb_graphsage.py        # Scriptified training entry point
├── notebooks/
│   ├── prb_graphsage_gnn_demo.ipynb       # Main ML4G term project notebook (full pipeline)
│   └── prb_graphsage_gnn_full_dataset.py  # PRBGraph model architecture with first two full runs of OpenAirInterface (OAI) benign + attack data
├── requirements.txt              # Python dependencies
└── README.md                     # This file
```

---

## Installation

Create a fresh environment (conda, venv, etc.) with **Python 3.9+** recommended.

```bash
git clone <this-repo-url>
cd <this-repo>

# DGX Spark's native Python venv was used within this pipeline, installing additional dependencies with pip as required.
```

`requirements.txt` should include, at minimum:

* `torch` (PyTorch)
* `torch-geometric` (PyG)
* `pandas`
* `numpy`
* `pyarrow`
* `scikit-learn` (optional, if you want richer metrics/plots)
* `jupyter` / `ipykernel` for notebook work

Consult PyTorch & PyG installation guides for the exact wheel commands for your CUDA / CPU setup.

---

## Data Pipeline

### 1. Preprocessing (TTI-Trust)

1. Place the raw PF logs in `data/`:

   ```text
   data/
   ├── prb_tti_evidence_ai_attack.csv
   └── prb_tti_evidence_ai_benign.csv
   ```

   For repo size reasons, the notebook also supports **shim** files (smaller subsets) under `data/shims/` with the same schema.

2. Run preprocessing to convert CSV → parquet and generate window shards (from the `demo` notebook:

   This produces:

   ```text
   parquet/
   ├── attack/run_id=...
   └── benign/run_id=...

   win_shards/
   ├── short_s*_attack_..._meta.parquet
   ├── short_s*_benign_..._meta.parquet
   ├── long_s*_...
   └── ...
   ```

### 2. PRB-Graph Graph Construction

The UE-level graph dataloader lives in `prb_graph_dataloader.py`. It:

* Reads the per-run parquet PF logs (`parquet/{attack,benign}/run_id=*`)
* Reads the window metadata (`win_shards/{short,long}_*_meta.parquet`)
* For each window, builds a `torch_geometric.data.Data` object:

  ```python
  from prb_graph_dataloader import make_prb_graph_loaders, detect_node_dim

  train_loader, val_loader, graph_meta, splits = make_prb_graph_loaders(
      kind="short",           # or "long"
      batch_size=32,
      val_ratio=0.2,
      label_mode="binary",    # attack vs non-attack
      max_windows=None,       # or a small number for rapid prototyping
  )

  D_NODE = detect_node_dim(train_loader)
  ```

Each graph has:

* `x`: [num_ues, d_node] node features
* `edge_index`: [2, num_edges] co-scheduling edges
* `y`: scalar label (0 = non-attack, 1 = attack)

---

## Model Architecture (PRB-GraphSAGE)

The model is defined in `models/prb_graphsage.py` (or in a notebook cell):

```python
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch_geometric.nn import (
    SAGEConv,
    GCNConv,
    GraphConv,
    GATv2Conv,
    global_mean_pool,
    global_max_pool,
)

class PRBGraphSAGE(nn.Module):
    """
    UE-level contention graph classifier for PRB starvation detection.
    """
    def __init__(
        self,
        in_dim: int,
        hidden_dim: int = 64,
        num_layers: int = 2,
        conv_type: str = "sage",
        aggr: str = "mean",
        mlp_hidden_dim: int = 64,
        mlp_layers: int = 2,
        dropout: float = 0.1,
        num_classes: int = 1,
        use_batchnorm: bool = True,
    ):
        super().__init__()
        # ... (see full implementation in the repo)
```

**Key features:**

* Pluggable conv types (`sage`, `gcn`, `graph`, `gat`)
* Global pooling (`mean`, `max`, or `mean+max`)
* Flexible depth/width and MLP head
* `num_classes=1` for `BCEWithLogitsLoss` in binary mode

---

## Training & Evaluation

The main training loop lives in the notebook and/or `train_prb_graphsage.py`:

* Supports hyperparameter sweeps through a `GNN_HYP` dict.
* Uses **early stopping** on validation F1.
* Logs per-epoch train/val loss + F1.
* Restores the best model weights before evaluation.

Example usage (from the notebook):

```python
best_overall = None
best_cfg = None

for cfg in iter_gnn_configs(GNN_HYP):
    print("\n=== Config:", cfg["conv_type"], cfg["hidden_dim"], cfg["num_layers"],
          cfg["dropout"], cfg["aggr"], "lr", cfg["lr"], "===")
    out = train_gnn_model(cfg, train_loader, val_loader, in_dim=D_NODE, device=DEVICE)

    if best_overall is None or out["best_metric"] > best_overall["best_metric"]:
        best_overall = out
        best_cfg = cfg

print("\nBest config:", best_cfg)
print("Best validation", best_overall["best_monitor"], "=", best_overall["best_metric"])
```

Evaluation then uses:

```python
from evaluation_utils import evaluate_gnn_model, summarize_eval_split, confusion_from_probs

best_model = best_overall["model"].to(DEVICE)
train_metrics, train_y, train_p = evaluate_gnn_model(best_model, train_loader, DEVICE)
val_metrics,   val_y,   val_p   = evaluate_gnn_model(best_model, val_loader, DEVICE)

summarize_eval_split("train", train_metrics)
summarize_eval_split("val",   val_metrics)
print("val confusion:", confusion_from_probs(val_y, val_p))
```

---

## Important Disclaimer

> **⚠️ Prototype-Only Results — Not Tuned on Full Dataset**
>
> The current PRB-Graph experiments are run on **small shim subsets** and on the original simulator logs, which are known to suffer from:
>
> * host-OS timing jitter (breaking the true 0.5 ms TTI grid),
> * label noise in “attack vs benign” windows, and
> * extreme class imbalance on some splits.
>
> Because of these issues, the **full 30 GB dataset was *not* used for exhaustive tuning**, and the “best” model in the prototype sweep can still exhibit poor metrics (e.g., F1 near 0 when positives are effectively invisible under the current split).
>
> These results are intended to validate:
>
> * the **graph construction pipeline**, and
> * the **PRB-GraphSAGE architecture**
>
> only. **They are not production or publication-grade performance claims.**
>
> A proper hyperparameter search and evaluation will be performed once **cleaner PF ledgers are collected from a GPU-native NVIDIA AI RAN stack** (e.g., Aerial cuPHY/cuMAC on DGX Spark), where slot timing is enforced at the hardware level and label definitions are revisited.

---

## License

> This code is provided for academic and research prototyping purposes only. It requires re-tuning following the generation of a clean, high fidelity, real-time slot-granularity database (e.g. ClickHouse).

---

## Acknowledgements

* Original TTI-Trust preprocessing and feature pipeline from prior work on PF fairness.
* Course: **CPSC 8810 (ML4G)** at Clemson University.
* Inspiration and future deployment targets from **NVIDIA AI RAN / Aerial** research.

