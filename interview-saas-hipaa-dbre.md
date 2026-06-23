# Interview Prep — PostgreSQL DBRE/SRE (24×7 HIPAA SaaS)

A focused, **30-minute** prep for a conversation with the **technical leads**. This is a senior (10+ yr) reliability/ownership role, so they're testing **judgment, communication, and operational maturity** as much as raw Postgres trivia. Short interview = breadth + depth on a few things + how you *think*.

> Companion to [prep.md](prep.md) (the full skills-to-questions map). This file covers what's **specific to this JD**: SLOs/error budgets, **Datadog**, **HIPAA**, **Azure + Kubernetes**, **RepMgr/HAProxy/PgBouncer/PgBackRest**, **ITSM**, and **ETL** — plus a time-boxed game plan, behavioral stories, and questions to ask back.
>
> **Deep refs in this handbook:** [prep.md](prep.md) · [databases/docs/best-practices.md](databases/docs/best-practices.md) · [databases/docs/pgbouncer.md](databases/docs/pgbouncer.md) · [databases/scripts/](databases/scripts/)

---

## 0. Decode the JD (what they actually want)

| JD phrase | What they're really hiring for | Your one-liner |
|-----------|-------------------------------|----------------|
| "high-availability, high-throughput… critical DB systems… 24×7 SaaS" | You've run prod Postgres that can't go down | "I design for node loss without data loss — replication + automated failover + tested failover drills." |
| "service reliability through monitoring/alerting, **SLO-oriented metrics**, operational readiness" | SRE mindset, not just DBA | "I define SLIs/SLOs, alert on symptoms tied to the SLO, and gate launches with operational-readiness reviews." |
| "incident response, RCA, post-incident corrective actions" | Calm under fire + you close the loop | "Stop the bleeding, evidence-driven RCA, blameless postmortem with tracked action items." |
| "complying with **HIPAA** security policies" | Healthcare data discipline | "Least privilege, encryption in transit + at rest, pgAudit, access reviews, encrypted/tested backups, audit trails." |
| "**Datadog** observability… dashboards, alerts, service-level views" | You can build the observability, not just read it | "postgres integration → DBM → SLO monitors; dashboards grouped by availability/latency/saturation/maintenance." |
| "Automate with **Bash/Powershell/Python/Ansible**; IaC via **Ansible playbooks**; Terraform a plus" | Everything-as-code, idempotent | "No snowflakes — Ansible for config, Terraform for infra, all in version control behind CI." |
| "PgBouncer, PgBackRest, HAProxy, **RepMgr**" | You know the real PG HA stack | (see §4 — know each one's job) |
| "Azure & Kubernetes preferred" | Cloud + containerized Postgres | "Comfortable operating Postgres in Azure; aware of the trade-offs of running stateful DBs on K8s (operators, storage, PDBs)." |
| "Agile/DevOps… **ITSM** practices" | Change mgmt, incident/problem/change tickets | "I work change windows, RFCs, and incident/problem records — reversible changes, peer review." |

---

## 1. The 30-minute game plan

Budget your airtime — they'll spend a chunk on intro and let you ask questions, so the *technical core is only ~15 min*. Make every answer land.

| Time | Phase | Your goal |
|------|-------|-----------|
| 0–5 | **Intro / "tell me about yourself"** | 90-sec pitch (see §2). End on something that maps to *their* stack. |
| 5–20 | **Technical depth** | 3–4 targeted topics. Give the crisp answer, then *one* layer of depth to show mastery, then stop. Don't ramble. |
| 20–27 | **Scenario / behavioral** | One incident story (STAR), how you partner with teams, how you handle on-call. |
| 27–30 | **Your questions** | Ask 2–3 sharp questions (§7). Signals seniority and genuine interest. |

**Rules of thumb:** Lead with the headline, then support it. If you don't know something, say how you'd find out — seniors are trusted for judgment, not omniscience. Tie answers back to *reliability and data safety*.

---

## 2. Your 90-second pitch (fill in the brackets)

> "I'm a database/reliability engineer with [X] years running production PostgreSQL for [scale/throughput]. I focus on three things: **keeping it up** — HA with streaming replication and automated failover; **keeping it fast** — query/workload tuning driven by `pg_stat_statements` and `EXPLAIN ANALYZE`; and **keeping it safe** — PITR backups I actually test, plus least-privilege and audit for compliance. I treat ops as code — [Ansible/Terraform] — and I've built observability in [Datadog/Prometheus] so we catch problems before customers do. The part I enjoy most is incident response and turning each one into a runbook or an alert so it never bites us twice."

Then a sentence connecting to *their* world: HIPAA SaaS, 24×7, Azure/K8s.

---

## 3. Reliability / SRE framing (the differentiator for this role)

This is what separates "DBA" from the "DBRE/SRE" they're hiring. Be fluent here.

**SLI / SLO / error budget**
- **SLI** = a measured signal of user-visible health. For a DB service: query **latency** (p99), **availability** (successful connections / failed), **error rate**, replication **freshness**.
- **SLO** = the target for an SLI, e.g. "p99 read latency < 50ms, 99.9% of the time over 30 days."
- **Error budget** = `100% − SLO`. It's the allowed unreliability. If you're burning it fast, you freeze risky changes and focus on stability; if you have budget, you can ship faster. This balances reliability vs feature velocity.
- **Alert on symptoms (SLO burn), not causes.** Page on "p99 latency breaching / error budget burning fast," not on "CPU 80%." Cause-based alerts create noise; symptom-based alerts map to customer pain.

**Operational readiness review (ORR):** before a new system goes live, check: monitored? alerted? runbook exists? backup + tested restore? capacity headroom? failover tested? on-call trained? This directly answers their "ensure newly introduced systems are supportable."

**Likely questions**
- *"What SLIs would you define for a database service?"* → availability (connection success), latency (p99 read/write), correctness/error rate, and freshness (replication lag) for read replicas.
- *"How do you decide what to page on?"* → symptom-based, tied to SLO burn rate; everything else is a ticket/dashboard, not a page. Reduce alert fatigue.
- *"How do error budgets change behavior?"* → budget left → ship; budget burned → freeze and harden.

---

## 4. The PostgreSQL HA stack they named (know each component's job)

They list **PgBouncer, PgBackRest, HAProxy, RepMgr**. Be able to say what each does and how they fit together. (Note: your handbook leans Patroni; this JD says **RepMgr** — be ready to compare.)

```
        app clients
            │
        HAProxy        ← routes writes to primary, reads to replicas; health checks
            │
        PgBouncer      ← connection pooling (transaction mode) — bounds real backends
            │
   ┌────────┴────────┐
 Primary  ──repl──▶  Standby(s)     ← streaming replication
   │                    │
 RepMgr  ◀── manages ──▶ RepMgr      ← cluster registration, monitoring, failover/switchover
   │
 PgBackRest  ───▶ archive/backup storage   ← full/incr backups + WAL archive = PITR
```

| Component | Job | Key talking point |
|-----------|-----|-------------------|
| **PgBouncer** | Connection pooler | Each PG connection is a process (~5–10MB); pool instead of raising `max_connections`. Transaction mode = best reuse (mind prepared-statement/session-state caveats). → [pgbouncer.md](databases/docs/pgbouncer.md) |
| **HAProxy** | L4/L7 routing + health checks | Single endpoint for apps; routes write traffic to the current primary, can split reads to replicas. During failover it follows the new primary. |
| **RepMgr** | Replication management + failover | Registers nodes, monitors health, automates **failover** (promote a standby) and **switchover** (planned). Uses a **witness** node to avoid split-brain on partition. `repmgrd` is the daemon. |
| **PgBackRest** | Backup & restore | Parallel, compressed, incremental backups + WAL archive → **PITR**. Supports retention, encryption, and restore validation. |

**RepMgr vs Patroni (be ready):** RepMgr is lighter, no external DCS required, good for classic VM clusters. Patroni uses a **DCS (etcd/Consul)** with a consensus leader key — stronger split-brain guarantees and the common choice on Kubernetes. If they run RepMgr, know it; if they ask "why might you prefer Patroni," answer: DCS-backed leader election + fencing + native K8s fit.

**Avoiding split-brain (either tool):** fencing/STONITH of the old primary, a witness/quorum so a partitioned minority won't promote, and `pg_rewind` to safely rejoin a demoted old primary.

---

## 5. Datadog for Postgres (they emphasize it — get concrete)

Don't just say "I'd use Datadog." Show you know the pieces.

- **Collection:** the **Datadog Agent** + the **Postgres integration** (`postgres.d`) scrapes `pg_stat_*` views. Enable **Database Monitoring (DBM)** for query-level visibility (normalized query samples, plans, wait events) — the Datadog equivalent of `pg_stat_statements` + `EXPLAIN`.
- **What to dashboard (group by the four golden signals + DB maintenance):**
  - *Availability/replication:* connections vs `max_connections`, replication lag (bytes & seconds), primary/standby state.
  - *Latency/throughput:* query latency (p50/p99), TPS, lock waits, slow queries from DBM.
  - *Saturation:* CPU, memory, disk %, IO, `pg_wal` size, cache hit ratio (>99% OLTP).
  - *Maintenance/correctness:* dead tuples / bloat, **XID age vs wraparound**, checkpoint frequency (timed vs requested), inactive replication slots.
- **Alerting / monitors:** symptom + SLO-burn monitors (latency SLO, availability), plus must-have **safety alerts**: wraparound risk (`age(datfrozenxid)`), replication broken/lagging, inactive replication slot pinning WAL, disk filling, connections near max.
- **Service-level views:** SLO monitors in Datadog tracking the SLIs in §3; APM/service map to tie DB health to the customer-facing services it backs.
- **Plus/alternatives:** Prometheus `postgres_exporter` → Grafana is the OSS equivalent; **pganalyze** / **Percona PMM** are PG-specialist tools (deeper index/bloat/plan advice) — name them as complements.

**Likely questions**
- *"Walk me through building Postgres observability in Datadog."* → Agent + PG integration + DBM → dashboards by golden signals → SLO monitors + safety alerts → service-level views tied to APM.
- *"What's the difference between a dashboard and an alert?"* → Dashboards for exploration/triage; alerts only for actionable, symptom-level conditions worth a human's attention.

---

## 6. HIPAA / security (don't fumble this — it's a compliance role)

PHI means security is a first-class duty. Hit the pillars:

- **Access control / least privilege:** roles, `GRANT`/`REVOKE`, `ALTER DEFAULT PRIVILEGES`, **RLS** for tenant isolation; no shared superuser; named accounts; periodic **access reviews**; separation of duties.
- **Encryption in transit:** `ssl=on`, TLS, `scram-sha-256` auth, locked-down `pg_hba.conf` (never `trust` over a network), minimal `listen_addresses`.
- **Encryption at rest:** Postgres has **no built-in TDE** — use volume/filesystem encryption (LUKS / Azure Disk Encryption / cloud KMS) and **encrypted backups** (PgBackRest supports encryption).
- **Auditing:** **pgAudit** for who-did-what (DDL, reads of PHI), log connections/disconnections, ship logs to a central, tamper-evident store; retain per policy.
- **Compliance hygiene:** encrypted + **tested** backups, documented retention, change management (RFCs), and an auditable trail. *An untested backup isn't a backup.*

**Likely questions**
- *"How do you protect PHI in Postgres?"* → least privilege + RLS, TLS in transit, volume/KMS encryption at rest, pgAudit, encrypted backups, access reviews.
- *"Encryption at rest in Postgres specifically?"* → no native TDE; do it at storage/volume layer + KMS, plus encrypted backups.

---

## 7. Azure + Kubernetes + ETL (the "preferred/plus" items — be honest, show awareness)

These are "preferred/plus," so depth-of-awareness beats false expertise.

- **Azure:** Postgres options — **Azure Database for PostgreSQL (Flexible Server)** (managed: HA, backups, patching handled) vs **self-managed on VMs** (full control, you own HA/backup). Know the trade-off: managed reduces ops toil but limits low-level tuning/extensions.
- **Kubernetes:** running **stateful** Postgres needs care — use a mature **operator** (CloudNativePG, Crunchy/PGO, Zalando/Patroni), `StatefulSets`, durable `PersistentVolumes`, `PodDisruptionBudgets`, anti-affinity across zones, and readiness/liveness probes. Be candid: stateful DBs on K8s are doable but you respect the storage/failover complexity.
- **ETL in Python:** pipelines for moving/transforming data — idempotent, restartable, with data-quality checks and observability. Tools: plain Python + `psycopg`, `COPY` for bulk, orchestration via Airflow/cron; logical replication / CDC (`wal_level=logical`) for streaming.

If you lack hands-on with one: *"I haven't run Postgres on AKS in prod, but here's how I'd approach it / here's the analogous thing I have done."* Seniors are trusted to ramp.

---

## 8. Behavioral / ownership (10+ yr role — they test leadership too)

Have **2–3 STAR stories** ready (Situation, Task, Action, Result + the follow-up improvement):

1. **A performance fire** — slow query / saturation you diagnosed methodically (`pg_stat_activity` → `pg_stat_statements` → `EXPLAIN ANALYZE` → fix → verify) and the alert/runbook you added after.
2. **An HA / failover event** — a node loss or planned switchover; how you avoided data loss/split-brain and what you hardened.
3. **A near-miss you caught proactively** — wraparound risk, a filling disk from an inactive replication slot, an untested backup — caught by monitoring you built.

Other prompts to prep (map to JD bullets):
- *"Escalated technical guidance to other teams"* → a time you unblocked devs (e.g., fixed a bad migration / index strategy) and left them better equipped.
- *"Partner with technical leaders so new systems are supportable"* → your **operational-readiness review** habit (§3).
- *"On-call"* → your philosophy: reduce pages via good alerting, runbooks, blameless postmortems, sustainable rotation.
- *"ITSM"* → comfort with change/incident/problem records, RFCs, change windows, reversible changes.

**Framework for any incident question:** *Observe → orient → hypothesize → test → fix → verify → write it up.* Stop the bleeding first; root-cause with evidence, not guesses; one change at a time; blameless postmortem with tracked actions.

---

## 9. Smart questions to ask them (pick 2–3)

These signal seniority and that you'll thrive there:

- "What does the Postgres topology look like today — RepMgr or Patroni, how many replicas, sync or async, and what's your current RPO/RTO target?"
- "How mature is the SLO/error-budget practice for the data tier, and who owns those conversations with product?"
- "What's the biggest reliability pain right now — is it scaling throughput, on-call load, migration safety, or compliance overhead?"
- "How is on-call structured for the DB team, and what's the typical page volume? What would you want to improve?"
- "Where are you on Azure managed vs self-managed Postgres, and is Kubernetes in the picture for the data tier?"
- "How do HIPAA audit requirements shape day-to-day DB work here (access reviews, change approvals)?"

---

## 10. Rapid-fire cheat sheet (last glance before the call)

- **SLO vs SLI vs error budget:** measured signal → target → allowed unreliability; alert on **symptom/burn**, not CPU.
- **HA stack:** HAProxy (route) → PgBouncer (pool) → primary+standbys (stream repl) → RepMgr (failover, witness) → PgBackRest (PITR).
- **Split-brain prevention:** quorum/witness + fencing + `pg_rewind` to rejoin.
- **Datadog:** Agent + PG integration + **DBM** → dashboards (4 golden signals + maintenance) → SLO monitors + safety alerts.
- **HIPAA:** least privilege + RLS, TLS in transit, **no native TDE** (volume/KMS at rest), pgAudit, encrypted + tested backups, access reviews.
- **PgBouncer:** pool, don't raise `max_connections`; transaction mode; `sum(pool_size) ≤ max_connections`.
- **WAL filling disk:** suspect an **inactive replication slot** first.
- **Wraparound watch:** `age(datfrozenxid)` toward ~2.1B; freeze before `autovacuum_freeze_max_age`.
- **Cache hit target:** >99% OLTP.
- **Replica ≠ backup:** a replica faithfully replays a `DROP TABLE`; PITR protects against logical errors.
- **Azure/K8s:** managed (Flexible Server) trades tuning for less toil; stateful PG on K8s → use a mature operator + durable storage + PDBs.
- **Incident loop:** stop bleeding → evidence-based RCA → blameless postmortem → tracked actions + new alert/runbook.

> Deeper drills on internals (MVCC, WAL, vacuum, planner, PITR, consensus) are in [prep.md](prep.md) and [databases/docs/best-practices.md](databases/docs/best-practices.md).
