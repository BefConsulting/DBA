# Manager Round — STAR Stories & Behavioral Prep

Prep for the managerial / behavioral interview (culture, collaboration, ownership, remote fit). The technical KSAs live in [dbre.md](dbre.md); this doc is for the "tell me about a time when…" round.

---

## The STAR method

Structure every behavioral answer so it's concrete and lands the point.

| Letter | Cover | ~Time | Avoid |
|--------|-------|-------|-------|
| **S — Situation** | Scene, your role, what was at stake (brief) | ~15s | Over-explaining background |
| **T — Task** | *Your* specific responsibility/goal | ~10s | Being vague about your part |
| **A — Action** | What **you** did, step by step (say "I") | ~45–60s | Saying "we" so they can't tell what you did |
| **R — Result** | Outcome (quantified) + what you learned/changed | ~20s | Forgetting the result or the lesson |

**Rules:** weight it toward Action · say "I" not "we" · quantify the result · end with a lesson or durable change (alert, runbook) · keep to ~90s–2min · one story can answer several questions.

---

## Story 1 — Performance fire (slow query / outage)

- **S** — API latency spiked and parts of the app timed out, affecting live customers; I owned the database side.
- **T** — Restore performance fast, then find why a normally-fast workload fell over.
- **A** — Started at the top of the funnel: `pg_stat_activity` showed many active sessions on the same slow query; `pg_stat_statements` confirmed one query's total time had exploded. `EXPLAIN (ANALYZE, BUFFERS)` showed it had flipped to a sequential scan on a multi-million-row table with huge "Rows Removed by Filter" and heavy `shared read`. Root cause: recent data growth + stale statistics, so the planner abandoned the right index. Stabilized immediately with `ANALYZE`; then added a composite index matching the filter+sort so the plan stays stable as data grows.
- **R** — Latency recovered in minutes; the query went ~30s → single-digit ms. Added `pg_stat_statements`-based alerting on mean-time regressions so a plan flip pages us before customers notice. Lesson: statistics freshness is a reliability concern, not just a tuning detail.

*Also answers: "diagnosing under pressure," "technical strength."*

---

## Story 2 — HA / reliability near-miss (replication slot filling the disk)

- **S** — Alert that the primary's disk was filling fast — `pg_wal` had grown to where hitting 100% would shut down the primary and take production with it.
- **T** — Stop the disk filling without data loss or breaking replication, then prevent a repeat.
- **A** — `pg_replication_slots` showed an **inactive** slot: a standby had gone offline days earlier but its slot still forced the primary to retain all WAL since then. Confirmed the standby wasn't returning and no other consumer needed that WAL, then dropped the orphaned slot — the primary immediately recycled WAL and pressure dropped. Freed a little space and watched `pg_wal` shrink to confirm. To prevent recurrence: added alerting on inactive slots and retained-WAL size, and set `max_slot_wal_keep_size` so a dead slot can never again threaten the primary.
- **R** — Avoided a full primary outage, zero data loss. New alerts caught a similar orphaned slot months later — cleaned up in minutes, no incident. Lesson: replication slots are powerful but need guardrails; an unmonitored slot is a latent outage.

*Also answers: "reliability judgment," "grace under pressure," "proactive thinking."*

---

## Story 3 — Conflict / disagreement (resolved with data and respect)

- **S** — A developer wanted to ship a feature and proposed several new indexes to make its query fast; I was concerned about write performance on a very write-heavy table.
- **T** — Make the feature fast **without** quietly degrading writes — and keep it collaborative, not adversarial.
- **A** — Instead of just saying no, reproduced their query in staging. Used `EXPLAIN (ANALYZE, BUFFERS)` to show most proposed indexes weren't even used, and that one well-designed **composite index** covered the real access pattern. Measured the write impact — one index was a fine trade-off where five would measurably slow inserts. Walked through the evidence together so it was a shared conclusion.
- **R** — Shipped with one index; feature hit its latency target and writes stayed healthy. The developer learned to read a query plan and started looping me in earlier on schema changes. Lesson: disagreements go best when you replace opinions with evidence and make it a joint investigation.

*Also answers: "collaboration," "influencing without authority," "communication."*

---

## Story 4 — A mistake (own it, change what you do)

- **S** — Early on, I ran a plain `CREATE INDEX` on a large, busy table during business hours; it takes a lock that blocks writes and caused a few minutes of write contention.
- **T** — Limit the impact right then, and make sure I never caused that self-inflicted contention again.
- **A** — Cancelled the index build to release the lock and restore normal operation. Owned it immediately — told the team rather than letting it be a mystery. Re-ran as `CREATE INDEX CONCURRENTLY` (builds without blocking writes). Turned it into a process improvement: wrote a migration runbook/checklist — use `CONCURRENTLY`, set `lock_timeout` so migrations fail fast instead of blocking, run large DDL in low-traffic windows, test on staging first.
- **R** — Impact was small because I caught it fast; the runbook meant the whole team stopped hitting that class of problem — migrations became boring (exactly what you want). Lesson: with production databases, *how* you apply a change matters as much as the change itself, and owning a mistake openly turns it into a lasting improvement.

*Also answers: "how do you handle failure," "learning from feedback," "attention to risk."*

---

## Story 5 — Collaboration / mentoring win

- **S** — Product engineers frequently hit DB performance questions but had no consistent way to diagnose them, so issues reached me late, already as incidents.
- **T** — Make the wider team more self-sufficient with DB troubleshooting and reduce firefighting.
- **A** — Built a set of ready-to-run monitoring queries (active sessions/blocking, cache hit ratios, bloat/vacuum, slow queries, replication), each annotated with what to look for. Ran a knowledge-sharing session on reading `EXPLAIN` plans and spotting red flags (stale stats, missing indexes). Paired with developers on real queries they owned.
- **R** — Developers started catching and fixing their own slow queries before they became incidents; the questions that reached me were better-scoped. Cut the back-and-forth and freed me for higher-leverage work. What I enjoyed most: it scaled my impact — making the whole team better instead of being the single point of contact.

*Also answers: "leadership/seniority," "improving a process," "cross-team work." (Authentic — it's what this handbook is.)*

---

## Other likely behavioral questions (map to a story above)

| Question | Lead with |
|----------|-----------|
| "Walk me through a production incident." | Story 1 or 2 |
| "A time you disagreed with someone." | Story 3 |
| "A mistake you made." | Story 4 |
| "How do you prioritize when everything's urgent?" | Stabilize-first mindset (Story 1/2) |
| "A time you improved a process / automated something." | Story 4 or 5 |
| "How do you handle on-call / pressure?" | Story 2 |
| "How do you explain complex DB issues to non-technical folks?" | Story 3 (evidence + shared conclusion) |

---

## Questions to ask the managers (prepare 4–5)

- "How is the database/platform team structured, and how does it collaborate with product engineering?" *(Pat — Platform)*
- "What does on-call and incident response look like, and how mature is the automation around it?" *(Nate — Infrastructure)*
- "What are the biggest database/infra challenges the team is tackling right now?"
- "What does success look like in the first 3–6 months?"
- "How does the team balance reliability work against delivery pressure?"
- "What's your management style / how do you support your engineers?"

---

## Logistics checklist (Google Meet, cameras on)

- Test camera / mic / lighting / quiet space 15 min early; stable internet.
- **Have a physical photo ID within reach** — the ID check is legitimate/standard anti-fraud.
- Water, notepad, resume, and this doc + questions visible.
- Warm, camera-on presence; concise ~2-min answers; enthusiasm is part of the evaluation.

## Positioning one-liner
> "PostgreSQL-focused database/reliability engineer — I tune performance, design HA and backup/recovery, and troubleshoot production issues, backed by solid Linux and automation skills."

## Why Wavelo
Wavelo (a Tucows company) runs a telecom/MVNO **billing & subscription SaaS platform** — databases are the backbone of a billing-critical, multi-tenant system where **correctness, availability, and recoverability** directly affect customers' revenue. Remote-first. That's exactly the reliability-at-scale work I want to own.
