# Monitoring & SLOs — measuring database reliability

How to turn "is the database healthy?" into **numbers you can alert on and report against**. This guide focuses on the SRE vocabulary — **SLI, SLO, error budget** (and SLA) — applied concretely to PostgreSQL, with example metrics, queries, and alert rules.

**See also:** [best-practices.md](best-practices.md) (what to tune) · [pgbouncer.md](pgbouncer.md) (pool metrics) · [../scripts/](../scripts/) (the `pg_stat_*` queries behind these metrics) · [../../prep.md](../../prep.md) · [../../interview-saas-hipaa-dbre.md](../../interview-saas-hipaa-dbre.md)

> **The one-sentence model:** an **SLI** is *what you measure*, an **SLO** is *the target for it*, the **error budget** is *how much you're allowed to miss*, and an **SLA** is *the contractual promise to customers*.

---

## 1. The four terms, precisely

| Term | Full name | What it is | Example |
|------|-----------|------------|---------|
| **SLI** | Service Level **Indicator** | A measured signal of health, from the user's point of view. Usually `good events / valid events` as a %. | `99.95%` of queries returned without error last 5 min |
| **SLO** | Service Level **Objective** | The internal **target** for an SLI, over a window. | "≥ 99.9% of queries error-free over 30 days" |
| **Error budget** | — | `100% − SLO`. The amount of unreliability you're *allowed*. | `0.1%` → ~43 min/month of "bad" |
| **SLA** | Service Level **Agreement** | The **external, contractual** promise (often with penalties). Looser than the SLO. | "99.5% uptime or service credits" |

```
SLI  ──measures──▶  a number        (99.95%)
SLO  ──targets───▶  a goal for it    (≥ 99.9%)
budget = 100% − SLO                  (0.1% you may "spend")
SLA  ──promises──▶  customers        (99.5%, with penalties)   ← always looser than the SLO
```

**Why SLO is stricter than SLA:** you want your internal alarm to fire *before* you breach the customer contract. If the SLA is 99.5%, you might run a 99.9% SLO so you have room to react.

---

## 2. What makes a *good* SLI

A good SLI tracks something the **user actually feels**, and is expressed as a ratio:

```
SLI = good events / valid events × 100%
```

- **User-centric:** measure the experience (did the query succeed, was it fast?), not an internal cause (CPU %). CPU is a *cause/saturation* signal — useful for debugging, bad as an SLI.
- **A ratio with a clear numerator/denominator:** "good requests over total valid requests" is easy to reason about and aggregate.
- **Few and meaningful:** pick a handful that cover the worst ways the service can hurt users. More is not better.

The common SLI categories (the ones worth defining for almost any service):

| Category | Question it answers | DB example |
|----------|--------------------|------------|
| **Availability** | Can users use it at all? | `successful connections / connection attempts` |
| **Latency** | Is it fast enough? | `% of queries faster than 50ms` |
| **Correctness / errors** | Are responses right / non-erroring? | `non-error queries / total queries` |
| **Freshness** (for replicas) | How stale is the data? | `% of time replication lag < 5s` |
| **Throughput / saturation** | (usually a *signal*, not an SLI) | TPS, connections vs max — drives capacity, not the SLO |

---

## 3. PostgreSQL SLI examples (with where the number comes from)

These map directly to `pg_stat_*` views (see [../scripts/](../scripts/)).

### 3.1 Availability SLI
> *"The fraction of connection attempts that succeed."*

Source signals: `pg_stat_database` (`xact_commit`/`xact_rollback`), connection success/failure from the pooler (PgBouncer `SHOW STATS`) or the app, or external synthetic checks.

```sql
-- Rollback ratio as a rough error proxy (per database)
SELECT datname,
       xact_commit,
       xact_rollback,
       round(100.0 * xact_commit / nullif(xact_commit + xact_rollback, 0), 3) AS commit_pct
FROM pg_stat_database
WHERE datname = current_database();
```

### 3.2 Latency SLI
> *"The fraction of queries that complete under the latency threshold (e.g. 50ms)."*

Source: `pg_stat_statements` (`mean_exec_time`, `total_exec_time`, `calls`) or Datadog DBM / `auto_explain`.

```sql
-- Share of calls coming from "fast" statements (mean < 50ms)
SELECT
  round(100.0 * sum(calls) FILTER (WHERE mean_exec_time < 50) / nullif(sum(calls),0), 2)
    AS pct_calls_under_50ms
FROM pg_stat_statements;
```

> Note: `pg_stat_statements` gives you *per-statement means*, not a true per-request histogram. For real p99 latency SLIs, measure at the app/pooler/APM layer (Datadog DBM, histograms). Use the SQL above as an internal approximation.

### 3.3 Replication freshness SLI (read replicas)
> *"The fraction of time replicas are within the freshness target (e.g. < 5s behind)."*

```sql
-- On a standby: how far behind is replay, in seconds?
SELECT extract(epoch FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds;

-- On the primary: per-replica lag in bytes
SELECT client_addr,
       state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

### 3.4 Correctness / error SLI
> *"The fraction of queries that don't error."* Measured from app/driver error rates or log-based error counts; `xact_rollback` is a coarse proxy.

---

## 4. Turning SLIs into SLOs (worked example)

Pick the SLI, the target, and the window:

| SLI | SLO target | Window | Error budget |
|-----|-----------|--------|--------------|
| Query availability (non-error) | **99.9%** | 30 days rolling | 0.1% → **~43.2 min**/30d |
| Read latency (`< 50ms`) | **99.5%** | 30 days rolling | 0.5% of requests may be slow |
| Replica freshness (`< 5s`) | **99.0%** | 30 days rolling | ~7.2 h/30d of staleness allowed |

**Error budget in time** (handy reference for *availability* SLOs):

| SLO | Allowed "bad" per 30 days | per year |
|-----|---------------------------|----------|
| 99% | ~7.2 h | ~3.65 days |
| 99.9% ("three nines") | ~43.2 min | ~8.76 h |
| 99.95% | ~21.6 min | ~4.38 h |
| 99.99% ("four nines") | ~4.32 min | ~52.6 min |

---

## 5. Error budgets in practice

`error budget = 100% − SLO`. It converts reliability into something you can **spend**:

- **Budget remaining → ship.** You can take risks: deploy, migrate, run a risky `CREATE INDEX`.
- **Budget burning fast / exhausted → freeze.** Stop risky changes, focus engineering on stability until you recover.

**Burn rate** = how fast you're consuming the budget relative to "even" consumption.
- Burn rate `1` = you'll exactly exhaust the budget by the end of the window.
- Burn rate `10` = you'll exhaust it in 1/10th of the window → urgent.

This is the basis for **multi-window, multi-burn-rate alerts** (Google SRE): page on a *fast* burn (e.g. 2% of budget in 1 hour) **and** confirm with a slower window to cut false positives.

---

## 6. Alerting: symptoms (SLO burn), not causes

**The key principle:** page humans on **user-visible symptoms tied to the SLO**, not on raw resource causes. CPU at 80% might be totally fine; a latency-SLO burn is always worth attention.

| Page on (symptom / SLO burn) | Don't page on (cause — dashboard/ticket instead) |
|------------------------------|--------------------------------------------------|
| Latency SLO burning fast | CPU 80% |
| Availability/error budget burning | Single slow query (unless it burns the SLO) |
| Replication broken / freshness SLO breached | Memory 70% |

**But** some **cause-based "safety" alerts are still must-haves** — conditions that *will* cause an outage if ignored, even before users feel it:

- **XID wraparound risk** — `age(datfrozenxid)` approaching ~2.1B (catastrophic if hit).
- **Disk filling** — especially `pg_wal` growth.
- **Inactive replication slot** pinning WAL (the usual cause of `pg_wal` filling the disk).
- **Connections near `max_connections`.**
- **Backups failing / archive_command failing.**

```sql
-- Safety alert source: XID age toward wraparound
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database ORDER BY xid_age DESC;

-- Safety alert source: inactive replication slots retaining WAL
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE NOT active;
```

---

## 7. Example alert rules

### Prometheus / Alertmanager (with `postgres_exporter`)

```yaml
groups:
- name: postgres-slo
  rules:
  # Symptom: availability SLO burning fast (error ratio high over 5m AND 1h)
  - alert: PostgresErrorBudgetBurnFast
    expr: |
      (
        sum(rate(pg_stat_database_xact_rollback{datname="app"}[5m]))
        / sum(rate(pg_stat_database_xact_commit{datname="app"}[5m]) + rate(pg_stat_database_xact_rollback{datname="app"}[5m]))
      ) > 0.001
    for: 5m
    labels: { severity: page }
    annotations:
      summary: "Error ratio burning the 99.9% SLO budget fast"

- name: postgres-safety
  rules:
  # Safety: XID wraparound risk
  - alert: PostgresXIDWraparoundRisk
    expr: max(pg_database_xid_age) > 1500000000   # ~1.5B of ~2.1B
    for: 10m
    labels: { severity: page }
    annotations:
      summary: "XID age high — wraparound risk, check autovacuum/freeze"

  # Safety: replica too far behind (freshness)
  - alert: PostgresReplicaLagHigh
    expr: pg_replication_lag_seconds > 5
    for: 5m
    labels: { severity: ticket }
    annotations:
      summary: "Replica lag > 5s — freshness SLO at risk"

  # Saturation (cause): connections near max
  - alert: PostgresConnectionsNearMax
    expr: |
      sum(pg_stat_activity_count) by (instance)
      / max(pg_settings_max_connections) by (instance) > 0.85
    for: 5m
    labels: { severity: ticket }
    annotations:
      summary: "Connections > 85% of max_connections — pool or raise headroom"
```

### Datadog (monitor sketches)

- **SLO monitor:** define an SLO on a metric/monitor (e.g. "query latency < 50ms") with a 99.5% / 30-day target; Datadog tracks remaining error budget and burn rate for you.
- **Database Monitoring (DBM):** enable to get per-query latency, normalized samples, plans, and wait events (the Datadog analogue of `pg_stat_statements` + `EXPLAIN`).
- **Safety monitors** mirror the Prometheus ones above: XID age, replication lag, `pg_wal` size / inactive slots, disk %, connections vs max.

---

## 8. Dashboards: group by the four golden signals (+ DB maintenance)

A clean Postgres dashboard groups panels so triage is fast:

| Group | Panels |
|-------|--------|
| **Availability / replication** | up/down, connection success, replication lag (bytes & seconds), primary/standby state |
| **Latency / throughput** | query p50/p99 (DBM/APM), TPS, top queries by total time, lock waits |
| **Saturation** | CPU, memory, disk %, IO, `pg_wal` size, cache hit ratio (>99% OLTP target) |
| **Maintenance / correctness** | dead tuples / bloat, **XID age vs wraparound**, checkpoint frequency (timed vs requested), inactive replication slots, backup success/age |

> **Dashboard vs alert:** dashboards are for *exploration and triage*; alerts are only for *actionable, symptom-level* conditions worth waking someone. Everything you graph does **not** need an alert.

---

## 9. The collection pipeline

```
PostgreSQL  ──exposes──▶  pg_stat_* views
     │
     ├─▶ postgres_exporter ──▶ Prometheus ──▶ Grafana        (OSS stack)
     │                                  └────▶ Alertmanager
     │
     └─▶ Datadog Agent (Postgres integration + DBM) ──▶ Datadog dashboards / SLO monitors
```

- **OSS:** `postgres_exporter` (+ `node_exporter` for host) → **Prometheus** (TSDB) → **Grafana** (dashboards) + **Alertmanager** (routing).
- **Datadog:** Agent + Postgres integration scrapes the same `pg_stat_*` views; **DBM** adds query-level detail; **SLO monitors** track budgets.
- **PG-specialist tools:** **pganalyze**, **Percona PMM** — deeper index/bloat/plan insight; use as complements.

---

## 10. Quick reference

- **SLI** = measured ratio of good/valid events (user-visible). **SLO** = target for it over a window. **Budget** = `100% − SLO`. **SLA** = looser, contractual.
- **Good SLI** = user-centric ratio (availability, latency, errors, freshness) — *not* CPU.
- **Three nines (99.9%)** ≈ 43 min/month of allowed badness; **four nines** ≈ 4.3 min/month.
- **Alert on SLO burn (symptoms)**, not causes — *but* keep cause-based **safety** alerts: wraparound, disk/`pg_wal`, inactive slot, connections near max, backup failures.
- **Burn-rate alerts:** fast burn = urgent page; confirm with a second, slower window to cut noise.
- **Error budget left → ship; budget burned → freeze and harden.**
- **Dashboards** group by availability/replication, latency/throughput, saturation, maintenance — and dashboards ≠ alerts.

---

## Mapping to the interview

- *"What's the difference between SLI, SLO, and SLA?"* → measure / internal target / external promise; SLO is stricter than SLA so you react before breaching the contract.
- *"What SLIs would you pick for a database?"* → availability (connection success), latency (% under threshold), error rate, replica freshness — user-centric ratios, not CPU.
- *"What do you page on?"* → symptom/SLO-burn alerts, plus a short list of cause-based **safety** alerts (wraparound, disk, inactive slot, connection exhaustion). Reduce alert fatigue.
- *"How do error budgets change behavior?"* → budget remaining → ship/take risk; budget burned → freeze and focus on reliability.
