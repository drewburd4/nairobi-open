-- ============================================================================
-- Uninstall Nairobi Open from the shared Dispatch Supabase project.
-- ----------------------------------------------------------------------------
-- Run this in the DISPATCH project's SQL editor to remove every Nairobi Open
-- object once the tournament app has moved to its own project. It only touches
-- things named nairobi_* (every table and function this app created is
-- prefixed that way), so the Dispatch app's own tables, functions, and data
-- are left completely untouched. The shared pgcrypto extension is left alone.
--
-- Functions are dropped first, then tables; CASCADE also clears their
-- triggers, RLS policies, and grants. Safe to re-run.
-- ============================================================================

do $$
declare
  r record;
begin
  -- every nairobi_* function, any signature
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'nairobi\_%'
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;

  -- every nairobi_* table (cascades to triggers, policies, constraints)
  for r in
    select tablename
    from pg_tables
    where schemaname = 'public' and tablename like 'nairobi\_%'
  loop
    execute 'drop table if exists public.' || quote_ident(r.tablename) || ' cascade';
  end loop;
end $$;

-- Verify nothing is left behind (this should return zero rows):
select 'function' as kind, p.proname as name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'nairobi\_%'
union all
select 'table' as kind, tablename as name
from pg_tables
where schemaname = 'public' and tablename like 'nairobi\_%';
