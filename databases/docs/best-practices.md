# PostgreSQL Best-Practice Configuration

A checklist of what to tune at the **Linux host** level and in the **PostgreSQL** server for a production-grade deployment. Defaults ship conservative — these are the knobs that matter most.

**See also:** [wal-and-checkpoints.md](wal-and-checkpoints.md) (checkpoint sizing) · [deep-dive.md](deep-dive.md) §2 (memory/planner), §4 (security) · [performance-analysis.md](performance-analysis.md) · [../scripts/settings.sql](../scripts/settings.sql) (audit current values)

> **Golden rule:** change one thing, measure, repeat. Use `databases/scripts/settings.sql` to see current values, their `source`, and whether they need a restart.

---

## Part 1 — Linux host level

### Memory & overcommit
| Setting | Recommended | Why |
|---------|-------------|-----|
| `vm.overcommit_memory` | `2` | Stops the OOM killer from killing the postmaster; allocations fail predictably instead |
| `vm.overcommit_ratio` | `80`–`90` (with little/no swap) | Caps committable memory = swap + ratio% of RAM |
| `vm.swappiness` | `1` (or `0`–`10`) | Keep Postgres pages in RAM; avoid swapping the cache |
| Transparent Huge Pages (THP) | **disabled** (`never`) | THP defrag causes latency spikes/stalls under load |
| Explicit Huge Pages (`vm.nr_hugepages`) | size to cover `shared_buffers` | Reduces page-table overhead; pair with `huge_pages=try/on` in PG |

```bash
# Disable THP at runtime (persist via tuned/grub/systemd)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

### Dirty page writeback (smooths I/O, avoids checkpoint stalls)
| Setting | Recommended | Why |
|---------|-------------|-----|
| `vm.dirty_background_bytes` | e.g. `67108864` (64MB) | Start flushing early so dirty data doesn't pile up |
| `vm.dirty_bytes` | e.g. `536870912` (512MB) | Cap dirty data before forced synchronous writeback |

Prefer the `_bytes` variants over `_ratio` on large-RAM hosts (a ratio of RAM can be enormous).

### Storage & filesystem
- **Filesystem:** `ext4` or `xfs`. Avoid network filesystems (NFS) for the data directory.
- **Mount with `noatime`** to skip access-time writes.
- **Separate volumes** for data (`PGDATA`), WAL (`pg_wal`), and (optionally) temp — separates write patterns and I/O contention.
- **I/O scheduler:** `none`/`noop` for NVMe, `mq-deadline` for SSD; avoid `cfq`.
- Ensure **write barriers / reliable `fsync`** — disable volatile write caches without battery/flush, or you risk corruption on power loss.
- **RAID:** RAID10 for write-heavy; battery-backed write cache on the controller.

### CPU, NUMA, scheduling
- **CPU governor = `performance`** (avoid frequency scaling latency).
- On NUMA boxes, interleave memory or pin to avoid cross-node penalties; test `numactl --interleave=all`.

### Limits, network, misc
| Area | Recommended |
|------|-------------|
| File descriptors | High `LimitNOFILE` (e.g. `65535`) for the postgres service |
| `net.core.somaxconn` | `1024`+ (connection backlog) |
| TCP keepalives | Tune `net.ipv4.tcp_keepalive_time` for dead-peer detection |
| Time sync | Run `chrony`/NTP — critical for replication/log correlation |
| Security | Restrict `PGDATA` perms (`0700`, owned by `postgres`); firewall the port; SELinux/AppArmor enforcing |

> Note: modern PG (9.3+) uses `mmap` for shared memory, so legacy `kernel.shmmax`/`shmall` tuning is largely unnecessary unless you force `huge_pages`.

---

## Part 2 — PostgreSQL server (`postgresql.conf`)

### Memory
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `shared_buffers` | ~25% of RAM | Don't exceed ~40%; the OS cache does the rest |
| `effective_cache_size` | 50–75% of RAM | Planner hint only (not an allocation) — tells it how much is cacheable |
| `work_mem` | 16–64MB (workload-dependent) | **Per sort/hash node, per connection** — multiply by concurrency before raising |
| `maintenance_work_mem` | 512MB–2GB | Speeds VACUUM, index builds, restores |
| `autovacuum_work_mem` | inherit or set explicitly | Caps memory per autovacuum worker |
| `huge_pages` | `try` (or `on` once host huge pages configured) | Lower page-table overhead |

### WAL & checkpoints  ([details](wal-and-checkpoints.md))
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `wal_level` | `replica` (or `logical` if using logical repl/CDC) | |
| `max_wal_size` | large enough that checkpoints are time-triggered | Watch `checkpoints_req` ≈ 0 |
| `min_wal_size` | e.g. `1–2GB` | Keeps recycled segments to avoid churn |
| `checkpoint_timeout` | `15min` (`30min` for write-heavy) | Spreads I/O; longer = fewer full-page writes |
| `checkpoint_completion_target` | `0.9` | Spreads checkpoint writes across the interval |
| `wal_compression` | `on` | Less WAL volume, small CPU cost |
| `wal_buffers` | `16MB` (or `-1` auto) | |

### Durability (don't disable in production)
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `fsync` | `on` | **Never off in prod** — off risks corruption |
| `full_page_writes` | `on` | Protects against torn pages |
| `synchronous_commit` | `on` (relax to `off`/`local` only if you accept losing the last few txns) | Per-txn tunable for hot paths |

### Autovacuum (keep it aggressive at scale)
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `autovacuum` | `on` | Never disable globally |
| `autovacuum_max_workers` | `3`–`6` | More workers for many tables |
| `autovacuum_vacuum_scale_factor` | `0.05` (lower for big tables) | Default `0.2` waits too long on large tables; override per-table |
| `autovacuum_analyze_scale_factor` | `0.02`–`0.05` | Fresher planner stats |
| `autovacuum_vacuum_cost_limit` | raise (e.g. `2000`) | Default throttling is too gentle for busy systems |
| `autovacuum_naptime` | `15s`–`30s` | How often it checks |
| Freeze (`autovacuum_freeze_max_age`, etc.) | tune for high-XID workloads | See [deep-dive.md](deep-dive.md) §1.3 to avoid wraparound |

### Planner
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `random_page_cost` | `1.1` on SSD/NVMe | Default `4.0` assumes spinning disk and discourages index use |
| `effective_io_concurrency` | `200` for SSD/NVMe | Enables prefetch for bitmap scans |
| `default_statistics_target` | `100` (raise to `500`+ for skewed columns) | More histogram detail = better estimates |
| `jit` | `off` for OLTP, `on` for analytics | JIT helps long analytical queries, hurts short ones |

### Connections (cap them; pool instead)
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `max_connections` | modest (e.g. `100`–`200`) + **PgBouncer** | Each backend costs RAM; pooling beats raising this |
| `idle_in_transaction_session_timeout` | e.g. `5min` | Kills sessions that pin xmin and hold locks |
| `statement_timeout` | per-app (e.g. `30s`–`60s`) | Stops runaway queries |
| `lock_timeout` | e.g. `5s` | Fail fast instead of blocking on locks |
| `tcp_keepalives_idle/interval` | set | Detect dead clients |

### Logging & observability (turn these on early)
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `logging_collector` | `on` | |
| `log_min_duration_statement` | `1000` (1s) | Capture slow queries |
| `log_checkpoints` | `on` | See checkpoint frequency/cost |
| `log_lock_waits` | `on` | Surfaces lock contention |
| `log_temp_files` | `0` | Flags `work_mem` spills to disk |
| `log_autovacuum_min_duration` | `0` or `250ms` | Watch autovacuum behavior |
| `log_line_prefix` | `'%m [%p] %q%u@%d '` | Timestamps, pid, user, db |
| `track_io_timing` | `on` | Real I/O timing in `EXPLAIN`/stats |
| `shared_preload_libraries` | `pg_stat_statements` (+ `auto_explain`) | Top-query visibility; needs a restart |

### Replication (if applicable) ([details](ha-and-dr.md))
| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `max_wal_senders` | `10` | Enough for replicas + base backups |
| `max_replication_slots` | `10` | One per standby/subscriber |
| `hot_standby` | `on` | Read queries on standbys |
| `max_slot_wal_keep_size` | bound it | Prevents an inactive slot from filling `pg_wal` |
| `archive_mode` + `archive_command` | `on` + pgBackRest/WAL-G | Required for PITR |

### Security essentials ([details](deep-dive.md) §4)
| Setting | Recommended |
|---------|-------------|
| `listen_addresses` | only the interfaces you need (not `*` blindly) |
| `password_encryption` | `scram-sha-256` |
| `pg_hba.conf` | `scram-sha-256` + least-privilege host rules; no `trust` over network |
| `ssl` | `on` with valid certs (encrypt in transit) |

---

## Applying & verifying changes

```sql
-- Most params: persists to postgresql.auto.conf
ALTER SYSTEM SET random_page_cost = 1.1;
SELECT pg_reload_conf();           -- for 'sighup' context params

-- Check what needs a restart vs reload, and where a value came from:
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN ('shared_buffers','random_page_cost','max_connections');
```

- `context = postmaster` → **requires a full restart** (e.g. `shared_buffers`, `max_connections`, `shared_preload_libraries`).
- `context = sighup` → `pg_reload_conf()` / `SELECT pg_reload_conf();` is enough.
- `context = user/superuser` → can be set per-session or per-role/db.
- Audit everything non-default with the **"Settings changed from default"** query in [../scripts/settings.sql](../scripts/settings.sql).

## Sizing & validation tools
- **PGTune** / **pgconfig** — sane starting values from RAM/CPU/workload type.
- **pgbench** — load-test before/after a change.
- **`pg_stat_statements`** + [scripts/](../scripts/) — measure the real effect, don't guess.
