-- settings_check.sql — figure out IF and HOW a setting was changed
-- Run in psql:  \i scripts/settings_check.sql
--
-- Background — the columns that answer "was this changed?":
--   setting          = the value currently in effect
--   boot_val         = the compiled-in DEFAULT (what it would be if untouched)
--   reset_val        = what RESET would set it to in this session
--   source           = WHERE the current value came from:
--                        default              -> nobody changed it
--                        configuration file   -> postgresql.conf OR postgresql.auto.conf (ALTER SYSTEM)
--                        environment variable -> env var at startup (PGPORT, TZ, ...)
--                        command line         -> postgres -c name=value
--                        database / user      -> ALTER DATABASE/ROLE ... SET ...
--                        session / client     -> SET ... in this connection
--                        override             -> forced internally by the server
--   sourcefile/line  = exact file + line that set it (tells .conf vs .auto.conf)
--   context          = what it takes to APPLY a change:
--                        postmaster -> full restart   |  sighup -> pg_reload_conf()
--                        superuser/user -> SET per session / ALTER ROLE|DATABASE
--   pending_restart  = true means a restart-only value was edited but not yet restarted

\echo '=== 1. Settings changed from their DEFAULT (setting <> boot_val) ==='
\echo '    look: this is everything intentionally tuned on this server — review for surprises'
SELECT name,
       setting        AS current_value,
       boot_val       AS default_value,
       unit,
       source,
       context
FROM pg_settings
WHERE setting IS DISTINCT FROM boot_val
ORDER BY name;

\echo ''
\echo '=== 2. Where each non-default value came from (file + line) ==='
\echo '    look: sourcefile ending in postgresql.auto.conf = set via ALTER SYSTEM; else hand-edited .conf'
SELECT name,
       setting AS current_value,
       source,
       sourcefile,
       sourceline
FROM pg_settings
WHERE source NOT IN ('default', 'override')
ORDER BY source, name;

\echo ''
\echo '=== 3. Config-file entries and whether they are APPLIED (pg_file_settings) ==='
\echo '    look: applied=f means the file says one thing but the server is not using it'
\echo '          (needs reload, is restart-only, overridden by a later line, or has an error)'
SELECT name,
       setting AS file_value,
       applied,
       error,
       sourcefile,
       sourceline
FROM pg_file_settings
ORDER BY applied, name;

\echo ''
\echo '=== 4. Restart-only changes edited but NOT yet applied (pending_restart) ==='
\echo '    look: any rows here = you changed a postmaster-context param but have not restarted'
SELECT name,
       setting       AS running_value,
       boot_val      AS default_value,
       context,
       pending_restart
FROM pg_settings
WHERE pending_restart
ORDER BY name;

\echo ''
\echo '=== 5. Inspect ONE setting end-to-end (edit the name below) ==='
\echo '    look: source/sourcefile = how it was set; context = how to change it; pending_restart = restart needed?'
SELECT name, setting, unit, boot_val, reset_val,
       source, sourcefile, sourceline, context, pending_restart
FROM pg_settings
WHERE name = 'max_wal_size';   -- <-- change to the parameter you want to check

-- Typical workflow to change + verify:
--   ALTER SYSTEM SET max_wal_size = '4GB';   -- writes postgresql.auto.conf
--   SELECT pg_reload_conf();                 -- applies sighup params (restart for postmaster params)
--   -- then re-run query #5 above: expect source='configuration file',
--   --      sourcefile ~ postgresql.auto.conf, pending_restart=f
