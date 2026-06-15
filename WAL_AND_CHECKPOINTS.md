# WAL, Dirty Buffers & Checkpoints

How PostgreSQL gets **durability and speed at the same time**: a compact log written at commit (WAL) plus actual data pages flushed lazily later (dirty buffers), reconciled at checkpoints.

**See also:** [POSTGRESQL_DEEP_DIVE.md](POSTGRESQL_DEEP_DIVE.md) §1.2 · [CACHE.md](CACHE.md) · [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md)

---

## WAL vs Dirty Buffers — the core distinction

Two representations of the same change, with two different jobs: **WAL makes changes durable; dirty buffers make changes fast.**

| | **WAL record** | **Dirty buffer** |
|---|----------------|------------------|
| **What** | A small log entry describing *what changed* | A full 8KB data page in memory that *has* the change |
| **Where** | `pg_wal/` on disk (written almost immediately) | `shared_buffers` in RAM |
| **Form** | Sequential, append-only log | The actual table/index page |
| **Purpose** | **Durability** + recovery + replication | **Performance** — avoid random disk writes |
| **Write pattern** | Sequential (fast on any disk) | Random (scattered across data files) |
| **When it hits disk** | At/around **COMMIT** (fsync) | **Later**, lazily, at a checkpoint or under memory pressure |

---

## What is a dirty buffer?

PostgreSQL never edits table files directly on disk. It loads an 8KB page into `shared_buffers` (RAM), modifies it there, and marks it **dirty** (changed in memory, not yet written back to the data file).

```
UPDATE customers SET email='x' WHERE id=42;
        |
        v
Load page into shared_buffers (if not already there)
        |
        v
Modify the row in memory  ->  page is now DIRTY
                              (RAM has new data, disk file still has old data)
```

Writing each change straight to the data file would be a **random write** to a scattered location every time — slow. Batching dirty pages and flushing later (coalescing many changes to the same page into one write) is far more efficient.

---

## What is WAL?

Before the change is made to the buffer, PostgreSQL writes a **WAL record** — a compact description of the change — to the write-ahead log. At COMMIT, that record is **fsync'd to disk**.

```
UPDATE customers ...
        |
        v
1. Write WAL record ("on page X, set row 42 email='x'")  -> WAL buffer
2. Modify the data page in shared_buffers                 -> dirty buffer
        |
   COMMIT
        v
3. fsync WAL to disk   <-- THIS is what makes the commit durable
```

The WAL hits disk at commit; the dirty data page does **not**. The commit is safe the instant the WAL is flushed, even though the table page is still only in RAM.

---

## The rule: Write-Ahead (WAL-before-data)

> A dirty buffer may **never** be written to the data file before its corresponding WAL record is on disk.

This is the guarantee that makes the scheme safe. WAL is the source of truth for durability; the data file catches up later.

---

## What happens on a crash

Crash after COMMIT but **before** the dirty buffer was flushed:

```
On disk:  WAL has the change  OK      Data file has OLD data  (stale)
                |
          Server restarts
                |
                v
        Crash recovery / REDO:
        replay WAL records -> re-apply changes to data files
                |
                v
        Data file now has the committed change  OK
```

The dirty buffer was lost (RAM only), but the **WAL survived**, so recovery replays it and reconstructs the change. **No committed data is lost** — the entire point of WAL.

---

## Checkpoints — reconciling the two

A **checkpoint** flushes **all current dirty buffers** to the data files and records "everything up to WAL position X is safely persisted" (the redo point).

```
Checkpoint:
  - flush all dirty buffers -> data files
  - record the WAL redo point
  - WAL before that point is no longer needed for crash recovery (can recycle)
```

After a checkpoint, crash recovery only needs to replay WAL **since the last checkpoint** — so checkpoint frequency bounds recovery time.

```
Timeline:
  COMMIT ──> WAL on disk (durable) ──────────────►
                 |                                 |
           dirty buffer in RAM ───────────► CHECKPOINT flushes it to data file
```

### What triggers a checkpoint
- **Time:** every `checkpoint_timeout` (default 5 min)
- **Volume:** WAL since last checkpoint approaches `max_wal_size` (default 1GB)
- **Manual:** `CHECKPOINT;` command
- **Events:** shutdown, `pg_basebackup`, etc.

### Key checkpoint parameters
| Parameter | Default | Role |
|-----------|---------|------|
| `checkpoint_timeout` | 5min | Max time between checkpoints |
| `max_wal_size` | 1GB | Soft cap on WAL before a checkpoint is forced |
| `min_wal_size` | 80MB | Floor for recycled WAL files |
| `checkpoint_completion_target` | 0.9 | Spread the flush over this fraction of the interval (smooths I/O) |

---

## Analogy

A busy kitchen:

- **WAL** = the **order ticket** written immediately and pinned up. Compact, sequential, never lost. If the kitchen burns down, the tickets tell you exactly what to remake.
- **Dirty buffer** = the **half-plated dish** on the counter. The real food, but rebuildable from the ticket if lost.
- **Checkpoint** = periodically **delivering all finished plates** to tables and clearing tickets you no longer need.

---

## Why both exist

| If you only had... | Problem |
|--------------------|---------|
| Only dirty buffers (no WAL) | A crash loses everything in RAM → committed data lost → no durability |
| Only WAL, flush data every commit | Every commit = slow random writes to data files → terrible performance |

Together: **commit = one fast sequential WAL write (durable)** + **data files updated lazily in batches (fast)**. Durability *and* speed.

---

## Operational issues (DBRE relevance)

| Symptom | Cause / fix |
|---------|-------------|
| **WAL fills the disk** | Inactive replication slot or failing `archive_command` prevents WAL recycling → see deep dive §1.2 |
| **Checkpoint I/O spikes / latency** | Too many dirty buffers flushed at once → raise `max_wal_size`, set `checkpoint_completion_target=0.9` |
| **Slow commits** | `fsync` storage latency on WAL → put `pg_wal` on fast disk |
| **Long crash recovery** | Checkpoints too far apart → lower `checkpoint_timeout` / `max_wal_size` (trades steady-state I/O for faster recovery) |
| **`shared_buffers` too small** | Pages evicted while still dirty → extra I/O churn |

Monitor:
```sql
-- Checkpoint & dirty-buffer activity (PG16: pg_stat_checkpointer; older: pg_stat_bgwriter)
SELECT * FROM pg_stat_bgwriter;
-- buffers_checkpoint  = pages written by checkpoints
-- buffers_clean       = pages written by background writer
-- buffers_backend     = pages a backend had to write itself (pressure signal)

SELECT pg_current_wal_lsn();           -- current WAL write position
SELECT checkpoint_lsn FROM pg_control_checkpoint();  -- last checkpoint location
```

Tip: frequent `buffers_backend` writes mean backends are flushing dirty pages themselves because the bgwriter/checkpointer can't keep up — a sign to tune checkpoint/bgwriter settings.

---

## One-liner for the interview

> *"A dirty buffer is the actual 8KB data page modified in RAM but not yet written to the data file; the WAL record is a compact, sequential log of that change flushed to disk at commit. WAL is written before the data page (write-ahead rule) and gives durability — on crash it's replayed to recover changes whose dirty buffers were lost. Checkpoints flush all dirty buffers to data files and advance the redo point, turning slow random writes into fast sequential WAL plus batched flushing. Checkpoint frequency trades steady-state I/O against crash-recovery time."*
