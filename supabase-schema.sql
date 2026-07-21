-- ============================================================
-- Nairobi Open: full Supabase schema
-- Run this once in the Supabase SQL editor on a fresh project.
-- The admin PIN is set to 0727 near the bottom; change it later
-- any time from the app's Admin tab.
--
-- Security model:
--   * Anyone with the link can read everything (live standings).
--   * Anyone can enter a score for a match that has no score yet.
--   * Everything else (overrides, postponing, events, brackets,
--     team edits) goes through functions that check the admin PIN.
--   * No direct insert/update/delete is allowed from the client.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- tables ----------

create table if not exists tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Nairobi Open',
  settings jsonb not null default '{"courts": 4}'::jsonb,
  admin_pin_hash text,
  created_at timestamptz not null default now()
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references tournaments(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  stage text not null default 'group',        -- 'group' or 'knockout'
  active boolean not null default false,      -- true while feeding the courts
  settings jsonb not null default '{"points_to_group": 21, "points_to_knockout": 21, "best_of_group": 1, "best_of_knockout": 1, "advance_per_group": 2, "knockout_size": "auto", "group_size": 6, "courts": [], "schedule_note": ""}'::jsonb,
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
  score1 int,                                 -- points (best of 1) or games won
  score2 int,
  games jsonb,                                -- [[21,15],[18,21],...] when best of 3/5
  status text not null default 'scheduled',   -- 'scheduled' or 'played'
  play_order numeric,
  postponed boolean not null default false,
  court int,                                  -- assigned court while waiting/playing
  walkover boolean not null default false,    -- won by default (no-show)
  called_at timestamptz,                      -- when the match was called to a court
  called_ack boolean not null default false,  -- desk confirmed players are on court
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

-- Internal: event setting with default.
create or replace function ev_int_setting(p_event_id uuid, p_key text, p_default int)
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(nullif(settings ->> p_key, '')::int, p_default) from events where id = p_event_id;
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

-- Internal: give free allocated courts to the next matches in line for an event.
create or replace function assign_courts(p_event_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  ev events;
  c int;
  next_id uuid;
begin
  select * into ev from events where id = p_event_id;
  if not found then return; end if;
  perform pg_advisory_xact_lock(hashtext(p_event_id::text));

  if not ev.active then
    update matches set court = null, updated_at = now()
    where event_id = p_event_id and status = 'scheduled' and court is not null;
    return;
  end if;

  -- drop assignments to courts no longer allocated to this event
  update matches set court = null, updated_at = now()
  where event_id = p_event_id and status = 'scheduled' and court is not null
    and not (court in (select (jsonb_array_elements_text(coalesce(ev.settings -> 'courts', '[]'::jsonb)))::int));

  for c in select (jsonb_array_elements_text(coalesce(ev.settings -> 'courts', '[]'::jsonb)))::int loop
    -- a court is busy if any scheduled match (any event) holds it
    if exists (select 1 from matches where status = 'scheduled' and court = c) then continue; end if;
    select id into next_id from matches
    where event_id = p_event_id and status = 'scheduled' and court is null
      and entrant1_id is not null and entrant2_id is not null
    order by play_order limit 1;
    exit when next_id is null;
    update matches set court = c, called_at = now(), called_ack = false, updated_at = now()
    where id = next_id;
  end loop;
end;
$$;

-- Internal: validate and normalize a score. Returns error text, or null and
-- sets out params. Games format: [[a,b],[a,b],...].
create or replace function check_score(
  p_event_id uuid, p_stage text, p_score1 int, p_score2 int, p_games jsonb, p_is_admin boolean,
  out o_err text, out o_score1 int, out o_score2 int, out o_games jsonb)
language plpgsql stable security definer set search_path = public
as $$
declare
  pts int;
  bo int;
  need int;
  w1 int := 0;
  w2 int := 0;
  g jsonb;
  a int;
  b int;
begin
  pts := ev_int_setting(p_event_id, case when p_stage = 'knockout' then 'points_to_knockout' else 'points_to_group' end, 21);
  bo := ev_int_setting(p_event_id, case when p_stage = 'knockout' then 'best_of_knockout' else 'best_of_group' end, 1);

  if bo > 1 then
    need := bo / 2 + 1;
    if p_games is null or jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) = 0 then
      o_err := 'Enter the game scores in order.'; return;
    end if;
    if jsonb_array_length(p_games) > bo then
      o_err := 'Best of ' || bo || ': that is too many games.'; return;
    end if;
    for g in select * from jsonb_array_elements(p_games) loop
      if w1 = need or w2 = need then
        o_err := 'The match was already decided; remove the extra games.'; return;
      end if;
      begin
        a := (g ->> 0)::int; b := (g ->> 1)::int;
      exception when others then
        o_err := 'Enter both scores as whole numbers.'; return;
      end;
      if a is null or b is null or a < 0 or b < 0 then o_err := 'Enter both scores as whole numbers.'; return; end if;
      if a = b then o_err := 'Scores cannot be tied.'; return; end if;
      if not p_is_admin then
        if greatest(a, b) <> pts then o_err := 'The winner needs exactly ' || pts || ' points.'; return; end if;
        if least(a, b) >= pts then o_err := 'The losing score must be under ' || pts || '.'; return; end if;
      end if;
      if a > b then w1 := w1 + 1; else w2 := w2 + 1; end if;
    end loop;
    if w1 < need and w2 < need then
      o_err := 'Best of ' || bo || ': someone needs ' || need || ' game wins.'; return;
    end if;
    o_score1 := w1; o_score2 := w2; o_games := p_games;
  else
    if p_score1 is null or p_score2 is null or p_score1 < 0 or p_score2 < 0 then
      o_err := 'Enter both scores as whole numbers.'; return;
    end if;
    if p_score1 = p_score2 then o_err := 'Scores cannot be tied.'; end if;
    if o_err is null and not p_is_admin then
      if greatest(p_score1, p_score2) <> pts then o_err := 'The winner needs exactly ' || pts || ' points.'; end if;
      if o_err is null and least(p_score1, p_score2) >= pts then o_err := 'The losing score must be under ' || pts || '.'; end if;
    end if;
    if o_err is null then
      o_score1 := p_score1; o_score2 := p_score2; o_games := null;
    end if;
  end if;
end;
$$;

-- ---------- public score entry (first entry only) ----------

create or replace function submit_score(p_match_id uuid, p_score1 int, p_score2 int, p_games jsonb default null)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  chk record;
begin
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status = 'played' then return 'A score is already in. Ask the desk to change it.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;

  select * into chk from check_score(m.event_id, m.stage, p_score1, p_score2, p_games, false);
  if chk.o_err is not null then return chk.o_err; end if;

  update matches
  set score1 = chk.o_score1, score2 = chk.o_score2, games = chk.o_games,
      status = 'played', postponed = false, court = null, walkover = false, updated_at = now()
  where id = p_match_id;

  perform advance_winner(p_match_id);
  perform assign_courts(m.event_id);
  return 'OK';
end;
$$;

-- ---------- admin functions ----------

create or replace function admin_submit_score(p_pin text, p_match_id uuid, p_score1 int, p_score2 int, p_games jsonb default null, p_walkover boolean default false)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  nm matches;
  chk record;
  old_w uuid;
  new_w uuid;
  v_s1 int;
  v_s2 int;
  v_games jsonb;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;

  if coalesce(p_walkover, false) then
    if p_score1 is null or p_score2 is null or p_score1 = p_score2 then return 'Bad walkover score.'; end if;
    v_s1 := p_score1; v_s2 := p_score2; v_games := null;
  else
    select * into chk from check_score(m.event_id, m.stage, p_score1, p_score2, p_games, true);
    if chk.o_err is not null then return chk.o_err; end if;
    v_s1 := chk.o_score1; v_s2 := chk.o_score2; v_games := chk.o_games;
  end if;

  new_w := case when v_s1 > v_s2 then m.entrant1_id else m.entrant2_id end;
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
  set score1 = v_s1, score2 = v_s2, games = v_games,
      status = 'played', postponed = false, court = null,
      walkover = coalesce(p_walkover, false), updated_at = now()
  where id = p_match_id;

  perform advance_winner(p_match_id);
  perform assign_courts(m.event_id);
  return 'OK';
end;
$$;

-- Dismiss the "go to court" banner: desk confirms players are on court.
create or replace function admin_ack_called(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  update matches set called_ack = true, updated_at = now() where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  return 'OK';
end;
$$;

-- Move a postponed (or any unplayed) match to the front of its event's queue.
create or replace function admin_play_next(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
  front numeric;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' then return 'That match already has a score.'; end if;
  select coalesce(min(play_order), m.play_order) - 1 into front
  from matches where event_id = m.event_id and status = 'scheduled' and id <> m.id;
  update matches set play_order = front, postponed = false, updated_at = now() where id = p_match_id;
  perform assign_courts(m.event_id);
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
  set score1 = null, score2 = null, games = null, walkover = false,
      status = 'scheduled', court = null, updated_at = now()
  where id = p_match_id;
  perform assign_courts(m.event_id);
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

  update matches set play_order = anchor, postponed = true, court = null, updated_at = now() where id = p_match_id;
  perform assign_courts(m.event_id);
  return 'OK';
end;
$$;

-- Internal: overlap check against other ACTIVE events' court allocations.
create or replace function courts_conflict(p_event_id uuid, p_courts jsonb)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  msg text;
begin
  select 'Court ' || string_agg(distinct cc.c::text, ', ') || ' is already used by ' || min(e2.name) || '.'
  into msg
  from events e2,
       lateral (select (jsonb_array_elements_text(coalesce(e2.settings -> 'courts', '[]'::jsonb)))::int as c) cc
  where e2.active and e2.id <> p_event_id
    and cc.c in (select (jsonb_array_elements_text(coalesce(p_courts, '[]'::jsonb)))::int);
  return msg;
end;
$$;

create or replace function admin_update_event(p_pin text, p_event_id uuid, p_name text, p_settings jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  ev events;
  conflict text;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into ev from events where id = p_event_id;
  if not found then return 'Event not found.'; end if;
  if ev.active then
    conflict := courts_conflict(p_event_id, coalesce(p_settings -> 'courts', '[]'::jsonb));
    if conflict is not null then return conflict; end if;
  end if;
  update events set name = coalesce(p_name, name), settings = coalesce(p_settings, settings)
  where id = p_event_id;
  perform assign_courts(p_event_id);
  return 'OK';
end;
$$;

create or replace function admin_set_active(p_pin text, p_event_id uuid, p_active boolean)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  ev events;
  conflict text;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into ev from events where id = p_event_id;
  if not found then return 'Event not found.'; end if;
  if p_active then
    if not exists (select 1 from matches where event_id = p_event_id) then
      return 'Draw groups first, then start the event.';
    end if;
    if jsonb_array_length(coalesce(ev.settings -> 'courts', '[]'::jsonb)) = 0 then
      return 'Pick at least one court, save, then start.';
    end if;
    conflict := courts_conflict(p_event_id, ev.settings -> 'courts');
    if conflict is not null then return conflict; end if;
  end if;
  update events set active = p_active where id = p_event_id;
  perform assign_courts(p_event_id);
  return 'OK';
end;
$$;

-- Creates an event (null p_event_id) or wipes and rebuilds an existing one.
-- The server forces event_id on every row so a payload can never write into
-- another event.
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
        stage = 'group',
        active = false
    where id = v_eid;
    if not found then return 'Event not found.'; end if;
    delete from matches where event_id = v_eid;
    delete from entrants where event_id = v_eid;
  end if;

  insert into entrants (id, event_id, name, group_name, seed)
  select (x ->> 'id')::uuid, v_eid, x ->> 'name', x ->> 'group_name', (x ->> 'seed')::int
  from jsonb_array_elements(coalesce(p_entrants, '[]'::jsonb)) x;

  insert into matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot)
  select (x ->> 'id')::uuid, v_eid, coalesce(x ->> 'stage', 'group'), x ->> 'group_name',
         (x ->> 'round')::int, (x ->> 'bracket_round')::int, (x ->> 'bracket_pos')::int,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         (x ->> 'score1')::int, (x ->> 'score2')::int, x -> 'games',
         coalesce(x ->> 'status', 'scheduled'), (x ->> 'play_order')::numeric,
         coalesce((x ->> 'postponed')::boolean, false),
         null, (x ->> 'next_match_id')::uuid, (x ->> 'next_slot')::int
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

create or replace function admin_rename_entrant(p_pin text, p_entrant_id uuid, p_name text)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if length(coalesce(trim(p_name), '')) = 0 then return 'Name cannot be empty.'; end if;
  update entrants set name = trim(p_name) where id = p_entrant_id;
  if not found then return 'Team not found.'; end if;
  return 'OK';
end;
$$;

create or replace function admin_remove_entrant(p_pin text, p_entrant_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  e entrants;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into e from entrants where id = p_entrant_id;
  if not found then return 'Team not found.'; end if;
  if exists (select 1 from matches where stage = 'knockout' and (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id)) then
    return 'They are in the knockout bracket. Edit the bracket or reset it first.';
  end if;
  delete from matches where entrant1_id = p_entrant_id or entrant2_id = p_entrant_id;
  delete from entrants where id = p_entrant_id;
  perform assign_courts(e.event_id);
  return 'OK';
end;
$$;

-- Adds one entrant plus their client-built catch-up matches.
create or replace function admin_add_entrant(p_pin text, p_event_id uuid, p_entrant jsonb, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from events where id = p_event_id) then return 'Event not found.'; end if;

  insert into entrants (id, event_id, name, group_name, seed)
  values ((p_entrant ->> 'id')::uuid, p_event_id, p_entrant ->> 'name', p_entrant ->> 'group_name', (p_entrant ->> 'seed')::int);

  insert into matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot)
  select (x ->> 'id')::uuid, p_event_id, coalesce(x ->> 'stage', 'group'), x ->> 'group_name',
         (x ->> 'round')::int, null, null,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         null, null, null, 'scheduled', (x ->> 'play_order')::numeric, false,
         null, null, null
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  perform assign_courts(p_event_id);
  return 'OK';
end;
$$;

-- Move an entrant to another group: their group matches are replaced with
-- client-built catch-up matches against the new group's members.
create or replace function admin_move_entrant(p_pin text, p_entrant_id uuid, p_group text, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  e entrants;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into e from entrants where id = p_entrant_id;
  if not found then return 'Team not found.'; end if;
  if exists (select 1 from matches where stage = 'knockout' and (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id)) then
    return 'They are in the knockout bracket. Edit the bracket or reset it first.';
  end if;

  delete from matches where stage = 'group' and (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id);
  update entrants set group_name = p_group where id = p_entrant_id;

  insert into matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot)
  select (x ->> 'id')::uuid, e.event_id, 'group', p_group,
         (x ->> 'round')::int, null, null,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         null, null, null, 'scheduled', (x ->> 'play_order')::numeric, false,
         null, null, null
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  perform assign_courts(e.event_id);
  return 'OK';
end;
$$;

-- Manual bracket fix: set either slot of an unplayed knockout match.
create or replace function admin_set_bracket_teams(p_pin text, p_match_id uuid, p_entrant1_id uuid, p_entrant2_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m matches;
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  select * into m from matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.stage <> 'knockout' then return 'Only knockout matches can be edited here.'; end if;
  if m.status = 'played' then return 'This match already has a score. Clear it first.'; end if;
  update matches set entrant1_id = p_entrant1_id, entrant2_id = p_entrant2_id, updated_at = now()
  where id = p_match_id;
  perform assign_courts(m.event_id);
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
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot)
  select (x ->> 'id')::uuid, p_event_id, 'knockout', null,
         (x ->> 'round')::int, (x ->> 'bracket_round')::int, (x ->> 'bracket_pos')::int,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         (x ->> 'score1')::int, (x ->> 'score2')::int, null,
         coalesce(x ->> 'status', 'scheduled'), (x ->> 'play_order')::numeric, false,
         null, (x ->> 'next_match_id')::uuid, (x ->> 'next_slot')::int
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  update events set stage = 'knockout' where id = p_event_id;
  perform assign_courts(p_event_id);
  return 'OK';
end;
$$;

create or replace function admin_reset_bracket(p_pin text, p_event_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from events where id = p_event_id) then return 'Event not found.'; end if;
  delete from matches where event_id = p_event_id and stage = 'knockout';
  update events set stage = 'group' where id = p_event_id;
  perform assign_courts(p_event_id);
  return 'OK';
end;
$$;

-- ---------- permissions ----------

revoke execute on function advance_winner(uuid) from public, anon, authenticated;
revoke execute on function assign_courts(uuid) from public, anon, authenticated;
revoke execute on function check_score(uuid, text, int, int, jsonb, boolean) from public, anon, authenticated;
revoke execute on function ev_int_setting(uuid, text, int) from public, anon, authenticated;
revoke execute on function courts_conflict(uuid, jsonb) from public, anon, authenticated;

grant execute on function verify_pin(text) to anon, authenticated;
grant execute on function change_admin_pin(text, text) to anon, authenticated;
grant execute on function submit_score(uuid, int, int, jsonb) to anon, authenticated;
grant execute on function admin_submit_score(text, uuid, int, int, jsonb, boolean) to anon, authenticated;
grant execute on function admin_clear_score(text, uuid) to anon, authenticated;
grant execute on function admin_postpone(text, uuid, boolean) to anon, authenticated;
grant execute on function admin_play_next(text, uuid) to anon, authenticated;
grant execute on function admin_ack_called(text, uuid) to anon, authenticated;
grant execute on function admin_move_entrant(text, uuid, text, jsonb) to anon, authenticated;
grant execute on function admin_update_event(text, uuid, text, jsonb) to anon, authenticated;
grant execute on function admin_set_active(text, uuid, boolean) to anon, authenticated;
grant execute on function admin_replace_event(text, uuid, text, int, jsonb, jsonb, jsonb) to anon, authenticated;
grant execute on function admin_delete_event(text, uuid) to anon, authenticated;
grant execute on function admin_rename_entrant(text, uuid, text) to anon, authenticated;
grant execute on function admin_remove_entrant(text, uuid) to anon, authenticated;
grant execute on function admin_add_entrant(text, uuid, jsonb, jsonb) to anon, authenticated;
grant execute on function admin_set_bracket_teams(text, uuid, uuid, uuid) to anon, authenticated;
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

-- ---------- seed data ----------
-- Tournament row with admin PIN 0727 (change any time from the Admin tab).

insert into tournaments (name, admin_pin_hash)
select 'Nairobi Open', crypt('0727', gen_salt('bf'))
where not exists (select 1 from tournaments);

-- All category events, ready to fill with entrants from the Admin tab.
insert into events (tournament_id, name, sort_order)
select t.id, v.name, v.ord
from tournaments t,
  (values
    ('Open Doubles (Men)', 0), ('Open Singles (Women)', 1), ('Open Singles (Men)', 2),
    ('Open Doubles (Women)', 3), ('Open Mixed Doubles', 4),
    ('Intermediate Singles (Men)', 5), ('Intermediate Singles (Women)', 6),
    ('Intermediate Doubles (Men)', 7), ('Intermediate Doubles (Women)', 8),
    ('Intermediate Mixed Doubles', 9),
    ('Masters Doubles (Men)', 10), ('Masters Doubles (Women)', 11), ('Masters Mixed Doubles', 12)
  ) as v(name, ord)
where not exists (select 1 from events);

-- ---------- sanity check ----------
select
  (select count(*) from tournaments) as tournaments,
  (select count(*) from events) as events,
  (select count(*) from entrants) as entrants,
  (select count(*) from matches) as matches;
