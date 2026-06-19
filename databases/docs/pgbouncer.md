# PgBouncer Setup — local macOS (PostgreSQL 16)

A hands-on guide to putting **PgBouncer** (a lightweight connection pooler) in front of your local PostgreSQL 16, why you'd do it, and how to operate and tune it.

**See also:** [best-practices.md](best-practices.md) (connections) · [performance-analysis.md](performance-analysis.md) · [deep-dive.md](deep-dive.md) §3

---

## Why a connection pooler?

Every PostgreSQL connection is a **separate OS process** with real memory overhead (~5–10MB+ each) and its own backend. Hundreds/thousands of short-lived app connections cause:
- memory pressure and context-switching overhead,
- connection storms that exhaust `max_connections`,
- slow connect/disconnect churn.

PgBouncer keeps a **small pool of real Postgres connections** and multiplexes many client connections over them. Apps connect to PgBouncer (cheap); PgBouncer reuses a handful of server connections (expensive). This is the standard answer to *"don't raise `max_connections` — pool instead."*

```
  many app clients ───▶  PgBouncer  ───▶  few real Postgres connections
   (cheap, transient)   (port 6432)        (port 5432, reused)
```

## Pool modes (pick based on your app)

| Mode | A server connection is returned to the pool... | Use when |
|------|-----------------------------------------------|----------|
| **session** | when the client disconnects | default; safest; least multiplexing |
| **transaction** | at the end of each transaction | **most common in production** — best reuse |
| **statement** | after each statement | autocommit-only; no multi-statement txns |

**Transaction mode** gives the best pooling but has caveats: no session-level features that span transactions (session-scoped `SET`, `LISTEN/NOTIFY`, advisory session locks, plain server-side prepared statements unless `max_prepared_statements` is set).

---

## 1. Install

```bash
brew install pgbouncer
pgbouncer --version
```

Homebrew puts the sample config at `/opt/homebrew/etc/pgbouncer.ini` (Apple Silicon).

## 2. Create a dedicated app role (with a password)

Local Homebrew Postgres often lets your Mac user in without a password, but PgBouncer authenticates to Postgres with credentials, so make a real login role:

```sql
-- in: psql -d pg_lab
CREATE ROLE app LOGIN PASSWORD 'app_pw';
GRANT ALL PRIVILEGES ON DATABASE pg_lab TO app;
GRANT ALL ON ALL TABLES IN SCHEMA public TO app;
```

Make sure `pg_hba.conf` allows SCRAM from localhost (it does by default on PG16):
```
host    all    all    127.0.0.1/32    scram-sha-256
```

## 3. Build the auth file (`userlist.txt`)

PgBouncer needs to verify the client's password. With SCRAM (PG16 default), copy the role's stored SCRAM verifier from the server into `userlist.txt`.

First create the config directory (it does not exist after a fresh install):

```bash
mkdir -p /opt/homebrew/etc/pgbouncer
```

Then generate the auth line. Keep it on **one line** and use `-tAc` so psql runs it as a query (a multi-line command with `\` and the SQL passed as the first argument is treated as a *connection string* and fails):

```bash
psql -d pg_lab -tAc "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"' FROM pg_authid WHERE rolname = 'app';" > /opt/homebrew/etc/pgbouncer/userlist.txt

cat /opt/homebrew/etc/pgbouncer/userlist.txt
# "app" "SCRAM-SHA-256$4096:...."
```

> - `-t` tuples-only, `-A` unaligned, `-c` run-and-exit — together they emit just the raw line.
> - `pg_authid` requires **superuser**; on Homebrew that's usually your Mac user, so add `-U <youruser>` if you get a permission error.
> - The `rolpassword` is the SCRAM verifier (not the plaintext) — safe to store.
> - Empty file / `0 rows`? The `app` role does not exist yet — do step 2 first, then re-run this.

## 4. Configure `pgbouncer.ini`

Create `/opt/homebrew/etc/pgbouncer/pgbouncer.ini`:

```ini
[databases]
; expose pg_lab through the pooler (clients connect to "pg_lab" on 6432)
pg_lab = host=127.0.0.1 port=5432 dbname=pg_lab

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432

; --- authentication ---
auth_type = scram-sha-256
auth_file = /opt/homebrew/etc/pgbouncer/userlist.txt

; --- pooling ---
pool_mode = transaction
max_client_conn = 1000      ; how many app clients can connect to PgBouncer
default_pool_size = 20      ; real server connections per (user,db) pair
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3

; --- admin / monitoring console ---
admin_users = app
stats_users = app

; --- logging ---
logfile = /opt/homebrew/var/log/pgbouncer.log
pidfile = /opt/homebrew/var/run/pgbouncer.pid
```

## 5. Start PgBouncer

```bash
mkdir -p /opt/homebrew/var/log /opt/homebrew/var/run

# foreground (see logs live):
pgbouncer /opt/homebrew/etc/pgbouncer/pgbouncer.ini

# or as a background service:
brew services start pgbouncer
```

## 6. Connect through the pooler

Apps now point at **port 6432** instead of 5432:

```bash
psql "host=127.0.0.1 port=6432 dbname=pg_lab user=app"   # password: app_pw
```

Everything works as normal — but connections are now pooled.

---

## 7. The admin console (monitoring)

Connect to the special `pgbouncer` database to inspect and control the pooler:

```bash
psql "host=127.0.0.1 port=6432 dbname=pgbouncer user=app"
```

| Command | Shows |
|---------|-------|
| `SHOW POOLS;` | per-pool active/waiting clients and server connections |
| `SHOW STATS;` | requests, query times, bytes per database |
| `SHOW CLIENTS;` | connected client connections |
| `SHOW SERVERS;` | actual server-side connections in use |
| `SHOW CONFIG;` | effective configuration |
| `RELOAD;` | re-read config + userlist without dropping clients |
| `PAUSE; / RESUME;` | drain/resume (e.g. for a failover or restart) |

Watch for `cl_waiting` > 0 in `SHOW POOLS` — clients are queuing because the pool is exhausted (raise `default_pool_size` or fix slow queries holding connections).

---

## 8. Tuning the key knobs

| Setting | What it controls | Guidance |
|---------|------------------|----------|
| `pool_mode` | when server conns return to pool | `transaction` for max reuse (mind the caveats) |
| `default_pool_size` | server conns per (user, db) | Start small (e.g. 20). A good rule: ≈ CPU cores × 2–4. Sum across pools must stay under Postgres `max_connections` |
| `max_client_conn` | total app clients allowed | Can be large (1000s) — that's the point of pooling |
| `min_pool_size` | warm idle conns kept ready | avoids cold-start latency |
| `reserve_pool_size` | extra conns for bursts | small buffer above default |
| `server_idle_timeout` | close idle server conns | reclaim unused conns |

> The math that matters: `sum(pool_size over all user/db pairs) ≤ Postgres max_connections` (leave headroom for superuser + maintenance). PgBouncer lets thousands of clients share a small, bounded set of real backends.

---

## 9. Application caveats (transaction mode)

- **Prepared statements:** plain protocol-level prepared statements break across pooled connections. Either set `max_prepared_statements` (PgBouncer 1.21+ supports this) or disable server-side prepares in your driver.
- **Session state:** don't rely on session-scoped `SET`, `LISTEN/NOTIFY`, `WITH HOLD` cursors, or session advisory locks — they may land on different server connections. Use `SET LOCAL` inside a transaction instead.
- **`search_path`/role per session:** set it per transaction, not once per connection.

If your app needs full session semantics, use **session** pool mode (less reuse, but no caveats).

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `password authentication failed` | `userlist.txt` verifier stale (regenerate after a password change); `auth_type` must match server (`scram-sha-256` on PG16) |
| `no such user` in PgBouncer log | role missing from `userlist.txt`, or wrong `auth_file` path |
| Clients hang / `cl_waiting` high | pool exhausted — raise `default_pool_size`, or fix slow/long transactions holding server conns |
| `pgbouncer cannot connect to server` | Postgres down, wrong host/port in `[databases]`, or `pg_hba.conf` rejects the pooler |
| Prepared-statement errors | transaction mode caveat — set `max_prepared_statements` or disable server-side prepares |
| Config change not taking | `RELOAD;` in the admin console, or restart the service |

---

## Mapping to the interview

- *"Why not just raise `max_connections`?"* → Each connection is a process with memory + scheduling cost; beyond a point more connections **reduce** throughput. A pooler bounds real backends while serving thousands of clients.
- *"Which pool mode and why?"* → Transaction mode for best reuse; call out the session-state/prepared-statement caveats to show depth.
- *"How do you size the pool?"* → `default_pool_size` ≈ cores × 2–4; total across pools under `max_connections`; watch `SHOW POOLS` `cl_waiting`.
- *"PgBouncer in HA?"* → Point it at the cluster's primary endpoint (e.g. HAProxy/Patroni); use `PAUSE`/`RESUME` to drain during failover. (See [patroni.md](patroni.md).)
