-- ============================================================================
-- Fix: shared, weighted court pool + clear the leftover per-event court locks
-- ----------------------------------------------------------------------------
-- Run this ONCE in the Dispatch project's SQL editor. It:
--   1. installs the weighted shared-pool nairobi_assign_courts()
--   2. installs nairobi_admin_assign_court() (tap a free court to place a match)
--   3. clears the old settings.courts locks that were pinning events to fixed
--      courts (e.g. Open Doubles -> [1,2], Open Singles -> [4]), which left the
--      other courts sitting idle
--   4. rebalances the courts immediately
--
-- These same function definitions also live in supabase-schema.sql. The step-3
-- cleanup is one-time; there is no need to run this file again.
-- ============================================================================

-- 1 + 2: functions ----------------------------------------------------------
create or replace function nairobi_assign_courts()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  total int;
  free_courts int[];
  rec record;
  allowed int[];
  chosen int;
begin
  select coalesce(nullif(settings ->> 'courts', '')::int, 4) into total from nairobi_tournaments limit 1;
  if total is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));

  update nairobi_matches m set court = null, updated_at = now()
  where m.status = 'scheduled' and m.court is not null
    and not exists (select 1 from nairobi_events e where e.id = m.event_id and e.active);

  select coalesce(array_agg(c order by c), '{}') into free_courts
  from generate_series(1, total) c
  where not exists (select 1 from nairobi_matches where status = 'scheduled' and court = c);

  for rec in
    select q.id, ev.settings as evsettings
    from (
      select m2.id, m2.event_id, m2.play_order,
             ((row_number() over (partition by m2.event_id order by m2.play_order) - 1) + 0.5)
               / count(*) over (partition by m2.event_id) as frac
      from nairobi_matches m2
      join nairobi_events e on e.id = m2.event_id and e.active
      where m2.status = 'scheduled' and m2.court is null
        and m2.entrant1_id is not null and m2.entrant2_id is not null
    ) q
    join nairobi_events ev on ev.id = q.event_id
    order by q.frac, ev.sort_order, q.play_order
  loop
    exit when array_length(free_courts, 1) is null;
    if rec.evsettings ? 'courts'
       and jsonb_typeof(rec.evsettings -> 'courts') = 'array'
       and jsonb_array_length(rec.evsettings -> 'courts') > 0 then
      select array_agg((value)::int) into allowed
      from jsonb_array_elements_text(rec.evsettings -> 'courts');
    else
      allowed := null;
    end if;

    select c into chosen from unnest(free_courts) c
    where allowed is null or c = any(allowed)
    order by c limit 1;

    if chosen is not null then
      update nairobi_matches
      set court = chosen, postponed = false, called_at = now(), called_ack = false, updated_at = now()
      where id = rec.id;
      free_courts := array_remove(free_courts, chosen);
    end if;
  end loop;
end;
$$;

create or replace function nairobi_admin_assign_court(p_pin text, p_match_id uuid, p_court int)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  total int;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select coalesce(nullif(settings ->> 'courts', '')::int, 4) into total from nairobi_tournaments limit 1;
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' or m.court is not null then return 'That match is not waiting for a court.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'This match''s teams are not set yet.'; end if;
  if p_court < 1 or p_court > total then return 'No such court.'; end if;
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  if exists (select 1 from nairobi_matches where status = 'scheduled' and court = p_court) then
    return 'Court ' || p_court || ' was just filled. Pick another.';
  end if;
  update nairobi_matches
  set court = p_court, postponed = false, called_at = now(), called_ack = false, updated_at = now()
  where id = p_match_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;
grant execute on function nairobi_admin_assign_court(text, uuid, int) to anon, authenticated;

-- 3: one-time cleanup of the leftover per-event court locks --------------------
update nairobi_events set settings = settings - 'courts' where settings ? 'courts';

-- 4: rebalance now ------------------------------------------------------------
do $$ begin perform nairobi_assign_courts(); end $$;
