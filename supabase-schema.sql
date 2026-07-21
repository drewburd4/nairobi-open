-- ============================================================
-- Pickleball Tournament: full Supabase schema
-- Run this once in the Supabase SQL editor on a fresh project.
--
-- IMPORTANT: change the admin PIN in the INSERT near the bottom
-- before running (search for CHANGE_ME). You can also change it
-- later from the app's Admin tab.
--
-- Security model:
--   * Anyone with the link can read everything (live standings).
--   * Anyone can enter a score for a match that has no score yet.
--   * Everything else (overrides, postponing, setup, brackets)
--     goes through functions that check the admin PIN.
--   * No direct insert/update/delete is allowed from the client.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- tables ----------

create table if not exists tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Pickleball Tournament',
  settings jsonb not null default '{"courts": 4}'::jsonb,
  admin_pin_hash text,
  created_at timestamptz not null default now()
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references tournaments(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  stage text not null default 'group',
  settings jsonb not null default '{"points_to_group": 21, "points_to_knockout": 21, "advance_per_group": 2, "group_size": 6}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists entrants (
  id uuid primary key,
  event_id uuid not null references events(id) on delete cascade,
  name text not null,
  group_name text,
  seed int,
  created_at timestamptz not null default now()
);

create table if not exists matches (
  id uuid primary key,
  event_id uuid not null references events(id) on delete cascade,
  stage text not null default 'group',        -- 'group' or 'knockout'
  group_name text,
  round int,
  bracket_round int,
  bracket_pos int,
  entrant1_id uuid references entrants(id) on delete set null,
  entrant2_id uuid references entrants(id) on delete set null,
  score1 int,
  score2 int,
  status text not null default 'scheduled',   -- 'scheduled' or 'played'
  play_order numeric,
  postponed boolean not null default false,
  next_match_id uuid,
  next_slot int,
  updated_at timestamptz not null default now()
);

create index if not exists matches_queue_idx on matches (event_id, status, play_order);

-- ---------- row level security: public read, no direct writes ----------

alter table tournaments enable row level security;
alter table events enable row level security;
alter table entrants enable row level security;
alter table matches enable row level security;

drop policy if exists "public read tournaments" on tournaments;
create policy "public read tournaments" on tournaments for select using (true);
drop policy if exists "public read events" on events;
create policy "public read events" on events for select using (true);
drop policy if exists "public read entrants" on entrants;
create policy "public read entrants" on entrants for select using (true);
drop policy if exists "public read matches" on matches;
create policy "public read matches" on matches for select using (true);

-- ---------- helpers ----------

create or replace function verify_pin(p_pin text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from tournaments
    where admin_pin_hash is not null
      and admin_pin_hash = crypt(p_pin, admin_pin_hash)
  );
$$;

create or replace function change_admin_pin(p_old text, p_new text)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_old) then return 'Wrong PIN.'; end if;
  if length(coalesce(p_new, '')) < 4 then return 'New PIN needs at least 4 characters.'; end if;
  update tournaments set admin_pin_hash = crypt(p_new, gen_salt('bf'));
  return 'OK';
end;
$$;

-- Internal: push a played match's winner into the next knockout round.
create or replace function advance_winner(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  w uuid;
begin
  select * into m from matches where id = p_match_id;
  if not found or m.next_match_id is null or m.status <> 'played' then return; end if;
  if m.score1 is null or m.score2 is null then return; end if;
  w := case when m.score1 > m.score2 then m.entrant1_id else m.entrant2_id end;
  if m.next_slot = 1 then
    update matches set entrant1_id = w, updated_at = now()
    where id = m.next_match_id and status = 'scheduled';
  else
    update matches set entrant2_id = w, updated_at = now()
    where id = m.next_match_id and status = 'scheduled';
  end if;
end;
$$;

-- ---------- public score entry (first entry only) ----------

create or replace function submit_score(p_match_id uuid, p_score1 int, p_score2 int)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  pts int;
begin
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status = 'played' then return 'A score is already in. Ask the desk to change it.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;

  select coalesce((e.settings ->> (case when m.stage = 'knockout' then 'points_to_knockout' else 'points_to_group' end))::int, 21)
    into pts from events e where e.id = m.event_id;

  if p_score1 is null or p_score2 is null or p_score1 < 0 or p_score2 < 0 then return 'Enter both scores as whole numbers.'; end if;
  if p_score1 = p_score2 then return 'Scores cannot be tied.'; end if;
  if greatest(p_score1, p_score2) <> pts then return 'The winner needs exactly ' || pts || ' points.'; end if;
  if least(p_score1, p_score2) >= pts then return 'The losing score must be under ' || pts || '.'; end if;

  update matches
  set score1 = p_score1, score2 = p_score2, status = 'played', postponed = false, updated_at = now()
  where id = p_match_id;

  perform advance_winner(p_match_id);
  return 'OK';
end;
$$;

-- ---------- admin functions ----------

create or replace function admin_submit_score(p_pin text, p_match_id uuid, p_score1 int, p_score2 int)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  nm matches;
  old_w uuid;
  new_w uuid;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;
  if p_score1 is null or p_score2 is null or p_score1 < 0 or p_score2 < 0 then return 'Enter both scores as whole numbers.'; end if;
  if p_score1 = p_score2 then return 'Scores cannot be tied.'; end if;

  new_w := case when p_score1 > p_score2 then m.entrant1_id else m.entrant2_id end;
  if m.next_match_id is not null then
    select * into nm from matches where id = m.next_match_id;
    if found and nm.status = 'played' then
      old_w := case when m.status = 'played' and m.score1 > m.score2 then m.entrant1_id
                    when m.status = 'played' then m.entrant2_id else null end;
      if old_w is distinct from new_w then
        return 'The next round already has a score. Clear it first.';
      end if;
    end if;
  end if;

  update matches
  set score1 = p_score1, score2 = p_score2, status = 'played', postponed = false, updated_at = now()
  where id = p_match_id;

  perform advance_winner(p_match_id);
  return 'OK';
end;
$$;

create or replace function admin_clear_score(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  nm matches;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;

  if m.next_match_id is not null then
    select * into nm from matches where id = m.next_match_id;
    if found and nm.status = 'played' then
      return 'The next round already has a score. Clear it first.';
    end if;
    if found then
      if m.next_slot = 1 then
        update matches set entrant1_id = null, updated_at = now() where id = nm.id;
      else
        update matches set entrant2_id = null, updated_at = now() where id = nm.id;
      end if;
    end if;
  end if;

  update matches
  set score1 = null, score2 = null, status = 'scheduled', updated_at = now()
  where id = p_match_id;
  return 'OK';
end;
$$;

create or replace function admin_postpone(p_pin text, p_match_id uuid, p_to_end boolean)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  anchor numeric;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' then return 'That match already has a score.'; end if;

  if p_to_end then
    select coalesce(max(play_order), m.play_order) + 10 into anchor
    from matches where event_id = m.event_id and status = 'scheduled' and id <> m.id;
  else
    select play_order + 1 into anchor
    from matches
    where event_id = m.event_id and status = 'scheduled' and id <> m.id and play_order > m.play_order
    order by play_order
    offset 7 limit 1;
    if anchor is null then
      select coalesce(max(play_order), m.play_order) + 10 into anchor
      from matches where event_id = m.event_id and status = 'scheduled' and id <> m.id;
    end if;
  end if;

  update matches set play_order = anchor, postponed = true, updated_at = now() where id = p_match_id;
  return 'OK';
end;
$$;

create or replace function admin_update_tournament(p_pin text, p_name text, p_settings jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  update tournaments set name = coalesce(p_name, name), settings = coalesce(p_settings, settings);
  return 'OK';
end;
$$;

create or replace function admin_update_event(p_pin text, p_event_id uuid, p_name text, p_settings jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  update events set name = coalesce(p_name, name), settings = coalesce(p_settings, settings)
  where id = p_event_id;
  if not found then return 'Event not found.'; end if;
  return 'OK';
end;
$$;

-- Creates an event (pass null p_event_id) or wipes and rebuilds an existing one.
-- Entrant and match rows come from the client as jsonb; the server forces
-- event_id on every row so a payload can never write into another event.
create or replace function admin_replace_event(
  p_pin text, p_event_id uuid, p_name text, p_sort_order int,
  p_settings jsonb, p_entrants jsonb, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_tid uuid;
  v_eid uuid;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select id into v_tid from tournaments limit 1;
  if v_tid is null then return 'No tournament row. Re-run the schema.'; end if;

  if p_event_id is null then
    insert into events (tournament_id, name, sort_order, settings)
    values (v_tid, p_name, coalesce(p_sort_order, 0), coalesce(p_settings, '{}'::jsonb))
    returning id into v_eid;
  else
    v_eid := p_event_id;
    update events
    set name = coalesce(p_name, name),
        sort_order = coalesce(p_sort_order, sort_order),
        settings = coalesce(p_settings, settings),
        stage = 'group'
    where id = v_eid;
    if not found then return 'Event not found.'; end if;
    delete from matches where event_id = v_eid;
    delete from entrants where event_id = v_eid;
  end if;

  insert into entrants (id, event_id, name, group_name, seed)
  select (x ->> 'id')::uuid, v_eid, x ->> 'name', x ->> 'group_name', (x ->> 'seed')::int
  from jsonb_array_elements(coalesce(p_entrants, '[]'::jsonb)) x;

  insert into matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, status, play_order, postponed,
                       next_match_id, next_slot)
  select (x ->> 'id')::uuid, v_eid, coalesce(x ->> 'stage', 'group'), x ->> 'group_name',
         (x ->> 'round')::int, (x ->> 'bracket_round')::int, (x ->> 'bracket_pos')::int,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         (x ->> 'score1')::int, (x ->> 'score2')::int,
         coalesce(x ->> 'status', 'scheduled'), (x ->> 'play_order')::numeric,
         coalesce((x ->> 'postponed')::boolean, false),
         (x ->> 'next_match_id')::uuid, (x ->> 'next_slot')::int
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  return 'OK:' || v_eid;
end;
$$;

create or replace function admin_delete_event(p_pin text, p_event_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  delete from events where id = p_event_id;
  if not found then return 'Event not found.'; end if;
  return 'OK';
end;
$$;

-- The client computes the seeded bracket rows; this validates the PIN,
-- replaces any existing knockout matches for the event, and flips its stage.
create or replace function admin_generate_bracket(p_pin text, p_event_id uuid, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from events where id = p_event_id) then return 'Event not found.'; end if;

  delete from matches where event_id = p_event_id and stage = 'knockout';

  insert into matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, status, play_order, postponed,
                       next_match_id, next_slot)
  select (x ->> 'id')::uuid, p_event_id, 'knockout', null,
         (x ->> 'round')::int, (x ->> 'bracket_round')::int, (x ->> 'bracket_pos')::int,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         (x ->> 'score1')::int, (x ->> 'score2')::int,
         coalesce(x ->> 'status', 'scheduled'), (x ->> 'play_order')::numeric, false,
         (x ->> 'next_match_id')::uuid, (x ->> 'next_slot')::int
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  update events set stage = 'knockout' where id = p_event_id;
  return 'OK';
end;
$$;

create or replace function admin_reset_bracket(p_pin text, p_event_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  delete from matches where event_id = p_event_id and stage = 'knockout';
  update events set stage = 'group' where id = p_event_id;
  if not found then return 'Event not found.'; end if;
  return 'OK';
end;
$$;

-- ---------- permissions ----------

-- advance_winner is internal only.
revoke execute on function advance_winner(uuid) from public, anon, authenticated;

grant execute on function verify_pin(text) to anon, authenticated;
grant execute on function change_admin_pin(text, text) to anon, authenticated;
grant execute on function submit_score(uuid, int, int) to anon, authenticated;
grant execute on function admin_submit_score(text, uuid, int, int) to anon, authenticated;
grant execute on function admin_clear_score(text, uuid) to anon, authenticated;
grant execute on function admin_postpone(text, uuid, boolean) to anon, authenticated;
grant execute on function admin_update_tournament(text, text, jsonb) to anon, authenticated;
grant execute on function admin_update_event(text, uuid, text, jsonb) to anon, authenticated;
grant execute on function admin_replace_event(text, uuid, text, int, jsonb, jsonb, jsonb) to anon, authenticated;
grant execute on function admin_delete_event(text, uuid) to anon, authenticated;
grant execute on function admin_generate_bracket(text, uuid, jsonb) to anon, authenticated;
grant execute on function admin_reset_bracket(text, uuid) to anon, authenticated;

-- ---------- realtime ----------

do $$ begin
  alter publication supabase_realtime add table matches;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table entrants;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table events;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table tournaments;
exception when others then null; end $$;

-- ---------- seed the tournament row ----------
-- CHANGE_ME: set your admin PIN here before running.

insert into tournaments (name, admin_pin_hash)
select 'Pickleball Tournament', crypt('CHANGE_ME', gen_salt('bf'))
where not exists (select 1 from tournaments);

-- ---------- sanity check ----------
select
  (select count(*) from tournaments) as tournaments,
  (select count(*) from events) as events,
  (select count(*) from entrants) as entrants,
  (select count(*) from matches) as matches;
