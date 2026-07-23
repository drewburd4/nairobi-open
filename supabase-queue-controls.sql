-- ============================================================================
-- Queue controls: reorder Up next, and pull-off-court with a chosen replacement
-- ----------------------------------------------------------------------------
-- Run this once in the Dispatch project's SQL editor. Adds two admin functions
-- the app now calls. Same definitions also live in supabase-schema.sql.
-- ============================================================================

create or replace function nairobi_admin_reorder_match(p_pin text, p_match_id uuid, p_dir text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  other nairobi_matches;
  tmp numeric;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' or m.court is not null then return 'That match is not waiting in the queue.'; end if;
  if p_dir = 'up' then
    select * into other from nairobi_matches
      where event_id = m.event_id and status = 'scheduled' and court is null and postponed = false
        and entrant1_id is not null and entrant2_id is not null and play_order < m.play_order
      order by play_order desc limit 1;
  else
    select * into other from nairobi_matches
      where event_id = m.event_id and status = 'scheduled' and court is null and postponed = false
        and entrant1_id is not null and entrant2_id is not null and play_order > m.play_order
      order by play_order asc limit 1;
  end if;
  if not found then return 'OK'; end if;
  tmp := m.play_order;
  update nairobi_matches set play_order = other.play_order, updated_at = now() where id = m.id;
  update nairobi_matches set play_order = tmp, updated_at = now() where id = other.id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;
grant execute on function nairobi_admin_reorder_match(text, uuid, text) to anon, authenticated;

create or replace function nairobi_admin_swap_to(p_pin text, p_off_match uuid, p_on_match uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  offm nairobi_matches;
  onm nairobi_matches;
  c int;
  front numeric;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if p_off_match = p_on_match then return 'Pick a different match.'; end if;
  select * into offm from nairobi_matches where id = p_off_match for update;
  if not found then return 'Match not found.'; end if;
  if offm.status <> 'scheduled' or offm.court is null then return 'That match is not on a court.'; end if;
  select * into onm from nairobi_matches where id = p_on_match for update;
  if not found then return 'The match to bring on was not found.'; end if;
  if onm.status <> 'scheduled' or onm.court is not null then return 'That match is not waiting for a court.'; end if;
  if onm.entrant1_id is null or onm.entrant2_id is null then return 'That match''s teams are not set yet.'; end if;
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  c := offm.court;
  update nairobi_matches
  set court = c, postponed = false, called_at = now(), called_ack = false, updated_at = now()
  where id = onm.id;
  select coalesce(min(play_order), offm.play_order) - 1 into front
  from nairobi_matches
  where event_id = offm.event_id and status = 'scheduled' and court is null and id <> offm.id;
  update nairobi_matches
  set court = null, play_order = front, postponed = false, called_at = null, called_ack = false, updated_at = now()
  where id = offm.id;
  return 'OK';
end;
$$;
grant execute on function nairobi_admin_swap_to(text, uuid, uuid) to anon, authenticated;
