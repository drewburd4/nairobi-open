-- ============================================================
-- Nairobi Open: full Supabase schema
--
-- Written to run inside the DISPATCH APP'S Supabase project (shared
-- for now, since the free plan's project slots are used). Everything
-- here is prefixed nairobi_ (tables and functions), so nothing touches
-- or collides with the Dispatch tables. Run this once in that
-- project's SQL editor. On a first install it invents a random admin PIN
-- and prints it in the result of the last statement, which is the only
-- time it is shown; change it later any time from the app's Admin tab.
--
-- Security model:
--   * Anyone with the link can read everything (live standings).
--   * Anyone can enter a score, but only for a match that is
--     currently assigned to a court and has no score yet.
--   * Everything else (overrides, postponing, events, brackets,
--     team edits) goes through functions that check the admin PIN.
--   * No direct insert/update/delete is allowed from the client.
--
-- To remove after the tournament: see the drop script commented out
-- at the very bottom of this file.
-- ============================================================

-- pgcrypto provides crypt()/gen_salt() for the bcrypt-hashed admin PIN.
-- Supabase preinstalls it in the "extensions" schema (where this is a
-- no-op); the search_path line makes it visible to this script's seed
-- insert at the bottom. The two PIN functions carry their own
-- "public, extensions" search_path for the same reason.
create extension if not exists pgcrypto with schema extensions;
set search_path = public, extensions;

-- ---------- tables ----------

create table if not exists nairobi_tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Nairobi Open 2026',
  settings jsonb not null default '{"courts": 4}'::jsonb,
  admin_pin_hash text,
  created_at timestamptz not null default now()
);

create table if not exists nairobi_events (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references nairobi_tournaments(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  stage text not null default 'group',        -- 'group' or 'knockout'
  active boolean not null default false,      -- true while feeding the courts
  settings jsonb not null default '{"points_to_group": 15, "points_to_knockout": 11, "best_of_group": 1, "best_of_knockout": 3, "win_by_two": true, "from_participants": true, "advance_per_group": 2, "knockout_size": "auto", "group_size": 6, "schedule_note": ""}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists nairobi_entrants (
  id uuid primary key,
  event_id uuid not null references nairobi_events(id) on delete cascade,
  name text not null,
  group_name text,
  seed int,
  -- Free-form per-entrant data; today: {dupr: 3.95, duprs: [4.1, 3.8]} from
  -- the CSV upload (team average used for snake seeding, individuals shown
  -- on the admin groups board). Unrated entrants just have {}.
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
-- Existing installs predate the meta column; add it in place.
alter table nairobi_entrants add column if not exists meta jsonb not null default '{}'::jsonb;

create table if not exists nairobi_matches (
  id uuid primary key,
  event_id uuid not null references nairobi_events(id) on delete cascade,
  stage text not null default 'group',        -- 'group' or 'knockout'
  group_name text,
  round int,
  bracket_round int,
  bracket_pos int,
  entrant1_id uuid references nairobi_entrants(id) on delete set null,
  entrant2_id uuid references nairobi_entrants(id) on delete set null,
  score1 int,                                 -- points (best of 1) or games won
  score2 int,
  games jsonb,                                -- [[21,15],[18,21],...] when best of 3/5
  status text not null default 'scheduled',   -- 'scheduled' or 'played'
  play_order numeric,
  postponed boolean not null default false,
  -- Held: taken off court and kept out of the queue until the desk puts it
  -- back. Postponing only moves a match down the order, so with nothing else
  -- waiting the assigner called the same match straight back on.
  held boolean not null default false,
  court int,                                  -- assigned court while waiting/playing
  walkover boolean not null default false,    -- won by default (no-show)
  called_at timestamptz,                      -- when the match was called to a court
  called_ack boolean not null default false,  -- desk confirmed players are on court
  next_match_id uuid,
  -- Where the LOSER goes. Only the third-place match is fed this way; every
  -- other knockout match leaves its loser out of the tournament.
  loser_match_id uuid,
  loser_slot int,
  next_slot int,
  updated_at timestamptz not null default now()
);

create index if not exists nairobi_matches_queue_idx on nairobi_matches (event_id, status, play_order);

-- ---------- participants ----------
-- The tournament's people, entered once and reused. An entrant row is whatever
-- plays a given event (a pair, in doubles); a participant is a human, with the
-- ratings and the DUPR id that follow them from event to event. `entries` maps
-- an event id to how they enter it: {"<event id>": {"partner": "Victor O."}}.
-- Unlike every other table here this one is NOT public: it carries gender and
-- DUPR ids for people who never agreed to publish them, so it has no read
-- policy and is reached only through the PIN checked functions below.
create table if not exists nairobi_participants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  gender text,                                -- 'M', 'F', or blank
  dupr_singles numeric,
  dupr_doubles numeric,
  dupr_id text,
  entries jsonb not null default '{}'::jsonb,
  sort_order numeric,
  updated_at timestamptz not null default now()
);

create index if not exists nairobi_participants_order_idx on nairobi_participants (sort_order);

-- ---------- score history ----------
-- Every write to a score, kept so a correction is never silent. A score that
-- changed after it was first entered is the one thing players argue about, and
-- until now the only trace was updated_at. Public, deliberately: the desk being
-- seen to change a score is what settles the argument on the spot.
create table if not exists nairobi_match_log (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references nairobi_matches(id) on delete cascade,
  at timestamptz not null default now(),
  action text not null,                       -- 'score', 'clear', 'walkover', 'retire'
  from_text text,                             -- what it was, null when nothing was there
  to_text text,                               -- what it became, null when cleared
  by_desk boolean not null default false      -- desk, or the players on court
);

create index if not exists nairobi_match_log_match_idx on nairobi_match_log (match_id, at);
-- The five-minute burst check on public score entry scans by time alone.
create index if not exists nairobi_match_log_at_idx on nairobi_match_log (at);

-- ---------- row level security: public read, no direct writes ----------

alter table nairobi_tournaments enable row level security;
alter table nairobi_events enable row level security;
alter table nairobi_entrants enable row level security;
alter table nairobi_matches enable row level security;
alter table nairobi_participants enable row level security;
alter table nairobi_match_log enable row level security;

drop policy if exists "public read nairobi_tournaments" on nairobi_tournaments;
create policy "public read nairobi_tournaments" on nairobi_tournaments for select using (true);
drop policy if exists "public read nairobi_events" on nairobi_events;
create policy "public read nairobi_events" on nairobi_events for select using (true);
drop policy if exists "public read nairobi_entrants" on nairobi_entrants;
create policy "public read nairobi_entrants" on nairobi_entrants for select using (true);
drop policy if exists "public read nairobi_matches" on nairobi_matches;
create policy "public read nairobi_matches" on nairobi_matches for select using (true);
drop policy if exists "public read nairobi_match_log" on nairobi_match_log;
create policy "public read nairobi_match_log" on nairobi_match_log for select using (true);

-- The admin PIN hash must never leave the database. Row level security is per
-- row, not per column, so the public read policy above would otherwise hand the
-- hash to anyone who asks for that column by name, and a 4 digit PIN behind a
-- readable hash cracks offline in no time with nothing to rate limit it.
-- A column level revoke alone would not bite while the role still holds a
-- table wide SELECT, so drop that first and grant back only the columns the app
-- actually reads. nairobi_verify_pin and nairobi_change_admin_pin are SECURITY
-- DEFINER, so they still see the column.
revoke select on nairobi_tournaments from anon, authenticated;
grant select (id, name, settings, created_at) on nairobi_tournaments to anon, authenticated;

-- Participants get no read policy at all, and the table grants come off too:
-- row level security is the only thing standing between the anon key and every
-- other table here, and this one holds data that must not leak even if a
-- policy is loosened by accident later. The functions below are SECURITY
-- DEFINER, so they still reach it.
revoke all on nairobi_participants from anon, authenticated;

do $$ begin
  alter publication supabase_realtime drop table nairobi_participants;
exception when others then null; end $$;

-- Same reason: realtime replays changed rows to subscribers, so leaving this
-- table in the publication would broadcast the new hash the moment the PIN is
-- changed. The tournament row is basically static during play, and the periodic
-- refresh picks up any change to it.
do $$ begin
  alter publication supabase_realtime drop table nairobi_tournaments;
exception when others then null; end $$;

-- ---------- migrations from earlier versions of this file ----------
-- (safe no-ops on a fresh install)

alter table nairobi_matches add column if not exists held boolean not null default false;

-- Who retired, when somebody started a match and could not finish it. Distinct
-- from a walkover, which is a no-show: a retirement was played, so the games
-- that were completed stand and their points count. Null on every other match.
alter table nairobi_matches add column if not exists retired uuid references nairobi_entrants(id) on delete set null;

drop function if exists nairobi_assign_courts(uuid);      -- replaced by the shared-pool nairobi_assign_courts()
drop function if exists nairobi_courts_conflict(uuid, jsonb);  -- per-event court allocation removed

-- ---------- helpers ----------

create or replace function nairobi_verify_pin(p_pin text)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select exists (
    select 1 from nairobi_tournaments
    where admin_pin_hash is not null
      and admin_pin_hash = crypt(p_pin, admin_pin_hash)
  );
$$;

create or replace function nairobi_change_admin_pin(p_old text, p_new text)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not nairobi_verify_pin(p_old) then return 'Wrong PIN.'; end if;
  if length(coalesce(p_new, '')) < 4 then return 'New PIN needs at least 4 characters.'; end if;
  -- Qualified deliberately. There is one tournament row, so the WHERE changes
  -- nothing here, but this is the same statement the README hands the organiser
  -- to paste into the Supabase SQL editor, and its safe mode refuses any
  -- UPDATE without a WHERE clause. Keep the two spellings identical.
  update nairobi_tournaments set admin_pin_hash = crypt(p_new, gen_salt('bf'))
   where id is not null;
  return 'OK';
end;
$$;

-- Internal: event setting with default. Anything that is not a clean integer
-- falls back to the default rather than raising, so one bad settings value
-- cannot take down score entry for a whole event.
create or replace function nairobi_ev_int_setting(p_event_id uuid, p_key text, p_default int)
returns int
language plpgsql stable security definer set search_path = public
as $$
declare
  raw text;
begin
  select nullif(settings ->> p_key, '') into raw from nairobi_events where id = p_event_id;
  if raw is null then return p_default; end if;
  return raw::int;
exception when others then
  return p_default;
end;
$$;

-- Internal: boolean event setting with default.
create or replace function nairobi_ev_bool_setting(p_event_id uuid, p_key text, p_default boolean)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare
  raw text;
begin
  select nullif(settings ->> p_key, '') into raw from nairobi_events where id = p_event_id;
  if raw is null then return p_default; end if;
  return raw::boolean;
exception when others then
  return p_default;
end;
$$;

-- Internal: push a played match's winner into the next knockout round.
-- p_old_winner: the feeder's winner BEFORE this (re)score, or null on a first
-- entry. The downstream slot is only overwritten when it is empty, already the
-- new winner, or still holds that old winner — a manual "Edit teams"
-- substitution in the next round survives a feeder correction.
drop function if exists nairobi_advance_winner(uuid);
create or replace function nairobi_advance_winner(p_match_id uuid, p_old_winner uuid default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  w uuid;
  l uuid;
  old_l uuid;
begin
  select * into m from nairobi_matches where id = p_match_id;
  if not found or m.status <> 'played' then return; end if;
  if m.score1 is null or m.score2 is null then return; end if;
  w := case when m.score1 > m.score2 then m.entrant1_id else m.entrant2_id end;
  l := case when m.score1 > m.score2 then m.entrant2_id else m.entrant1_id end;
  -- Whoever the old winner was, the old loser was this match's other team.
  old_l := case when p_old_winner is null then null
                when p_old_winner = m.entrant1_id then m.entrant2_id
                when p_old_winner = m.entrant2_id then m.entrant1_id
                else null end;

  if m.next_match_id is not null then
    if m.next_slot = 1 then
      update nairobi_matches set entrant1_id = w, updated_at = now()
      where id = m.next_match_id and status = 'scheduled'
        and (entrant1_id is null or entrant1_id = w or entrant1_id = p_old_winner);
    else
      update nairobi_matches set entrant2_id = w, updated_at = now()
      where id = m.next_match_id and status = 'scheduled'
        and (entrant2_id is null or entrant2_id = w or entrant2_id = p_old_winner);
    end if;
  end if;

  if m.loser_match_id is not null and l is not null then
    if m.loser_slot = 1 then
      update nairobi_matches set entrant1_id = l, updated_at = now()
      where id = m.loser_match_id and status = 'scheduled'
        and (entrant1_id is null or entrant1_id = l or entrant1_id = old_l);
    else
      update nairobi_matches set entrant2_id = l, updated_at = now()
      where id = m.loser_match_id and status = 'scheduled'
        and (entrant2_id is null or entrant2_id = l or entrant2_id = old_l);
    end if;
  end if;
end;
$$;

-- Internal: shared court pool. Court share is a blend: 35% divided evenly
-- between the running events and 65% by how many matches each still has
-- waiting, so a big draw finishes sooner without starving a small one.
-- A match only lands on a court its event may use: settings.courts (a JSON
-- array of court numbers) restricts an event; absent or empty means every
-- court. This is the same weave the app shows as "Up next".
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
  ae record;
  a_courts int[];
  a_free int[];
  busy_names text[];
begin
  -- numeric-guarded: a malformed value fails open to 4 rather than aborting
  -- every mutating RPC that runs through here
  select case when coalesce(settings ->> 'courts', '') ~ '^[0-9]+$'
              then (settings ->> 'courts')::int else 4 end
  into total from nairobi_tournaments limit 1;
  if total is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));

  update nairobi_matches m set court = null, updated_at = now()
  where m.status = 'scheduled' and m.court is not null
    and not exists (select 1 from nairobi_events e where e.id = m.event_id and e.active
                    -- an archived event's courts are released even while it is
                    -- still flagged active: archived leaves the app entirely,
                    -- so nothing could ever free them and they died for the day
                    and coalesce(e.settings ->> 'archived', '') <> 'true');

  -- ===== main draw pool: non-Americano events on courts 1..total. Americano is
  -- a physically separate event with its own courts, so it is handled below as
  -- its own pool and a shared court number never blocks across the two. =====
  select coalesce(array_agg(c order by c), '{}') into free_courts
  from generate_series(1, total) c
  where not exists (
    select 1 from nairobi_matches m join nairobi_events e on e.id = m.event_id
    where m.status = 'scheduled' and m.court = c
      and coalesce(e.settings ->> 'format', '') <> 'americano');

  -- People currently holding a main-pool court. A team's next match must not
  -- be called while they are mid-game on another court (happens at round
  -- boundaries and after postpones/moves), so the loop below skips it and
  -- takes the next eligible match instead.
  -- Matched on PLAYER NAME, not entrant id, the same way the Americano pool
  -- does it: somebody entered in two events has a separate entrant row in each,
  -- so an id-level test called them to two courts at once, which is exactly
  -- what happens when two events of a 13-event tournament share a day.
  select coalesce(array_agg(distinct p), '{}') into busy_names
  from (
    select unnest(string_to_array(en.name, ' & ')) as p
    from nairobi_matches m
    join nairobi_events e on e.id = m.event_id
    join nairobi_entrants en on en.id in (m.entrant1_id, m.entrant2_id)
    where m.status = 'scheduled' and m.court is not null
      and coalesce(e.settings ->> 'format', '') <> 'americano'
  ) s where p is not null and btrim(p) <> '';

  -- Court share is a blend (Drew's split, Aug 2026): 35% divided evenly
  -- between the running events and 65% by how many matches each still has, so
  -- a big draw still finishes sooner but can't starve a small one down to a
  -- single court. weight = 0.35 * (total/events) + 0.65 * own_count; one event
  -- alone reduces to the old pure-proportional order exactly. Mirrored in the
  -- client's weaveQueues and in nairobi_admin_swap_out below.
  for rec in
    select q.id, q.entrant1_id, q.entrant2_id, q.pnames, ev.settings as evsettings
    from (
      select qi.id, qi.event_id, qi.play_order, qi.entrant1_id, qi.entrant2_id, qi.pnames,
             ((qi.rn - 1) + 0.5)
               / (0.35 * (qi.total_n::numeric / max(qi.dr) over ()) + 0.65 * qi.ev_n) as frac
      from (
        select m2.id, m2.event_id, m2.play_order, m2.entrant1_id, m2.entrant2_id,
               (select array_agg(btrim(p)) from (
                  select unnest(string_to_array(e1.name, ' & ')) as p
                  union all
                  select unnest(string_to_array(e2.name, ' & '))) z) as pnames,
               row_number() over (partition by m2.event_id order by m2.play_order, m2.id) as rn,
               count(*) over (partition by m2.event_id) as ev_n,
               count(*) over () as total_n,
               dense_rank() over (order by m2.event_id) as dr
        from nairobi_matches m2
        join nairobi_events e on e.id = m2.event_id and e.active
          -- archived leaves the app entirely; it must not be CALLED either
          and coalesce(e.settings ->> 'archived', '') <> 'true'
        join nairobi_entrants e1 on e1.id = m2.entrant1_id
        join nairobi_entrants e2 on e2.id = m2.entrant2_id
        where m2.status = 'scheduled' and m2.court is null and not m2.held
          and m2.entrant1_id is not null and m2.entrant2_id is not null
          and coalesce(e.settings ->> 'format', '') <> 'americano'
      ) qi
    ) q
    join nairobi_events ev on ev.id = q.event_id
    order by q.frac, ev.sort_order, q.play_order, q.id
  loop
    exit when array_length(free_courts, 1) is null;
    if rec.pnames && busy_names then continue; end if;
    if rec.evsettings ? 'courts' and jsonb_typeof(rec.evsettings -> 'courts') = 'array'
       and jsonb_array_length(rec.evsettings -> 'courts') > 0 then
      select array_agg((value)::int) into allowed
      from jsonb_array_elements_text(rec.evsettings -> 'courts') where value ~ '^[0-9]+$';
    else allowed := null; end if;
    select c into chosen from unnest(free_courts) c where allowed is null or c = any(allowed) order by c limit 1;
    if chosen is not null then
      update nairobi_matches set court = chosen, postponed = false, held = false, called_at = now(), called_ack = false, updated_at = now()
      where id = rec.id;
      free_courts := array_remove(free_courts, chosen);
      busy_names := busy_names || rec.pnames;
    end if;
  end loop;

  -- ===== one independent pool per active Americano event, on its own courts.
  -- Per-player gate: a match takes a court only when none of its four players are
  -- on a court and it is their earliest unplayed match, so a box schedule lets
  -- each court run its rounds back to back without double-booking anyone. =====
  for ae in select * from nairobi_events where active and coalesce(settings ->> 'format', '') = 'americano'
            and coalesce(settings ->> 'archived', '') <> 'true' loop
    a_courts := null;
    if ae.settings ? 'courts' and jsonb_typeof(ae.settings -> 'courts') = 'array'
       and jsonb_array_length(ae.settings -> 'courts') > 0 then
      select array_agg((value)::int) into a_courts
      from jsonb_array_elements_text(ae.settings -> 'courts') where value ~ '^[0-9]+$';
    end if;
    if a_courts is null then a_courts := array[1, 2]; end if;
    -- a court number held by ANY americano event counts as taken, so two
    -- americano events sharing the default [1,2] cannot double-book
    select coalesce(array_agg(c order by c), '{}') into a_free
    from unnest(a_courts) c
    where not exists (select 1 from nairobi_matches m
                      join nairobi_events e2 on e2.id = m.event_id
                      where coalesce(e2.settings ->> 'format', '') = 'americano'
                        and m.status = 'scheduled' and m.court = c);

    for rec in
      select m2.id
      from nairobi_matches m2
      join nairobi_entrants ea on ea.id = m2.entrant1_id
      join nairobi_entrants eb on eb.id = m2.entrant2_id
      where m2.event_id = ae.id and m2.status = 'scheduled' and m2.court is null and not m2.held
        and m2.entrant1_id is not null and m2.entrant2_id is not null
        and not exists (
          select 1 from nairobi_matches g
          join nairobi_entrants ga on ga.id = g.entrant1_id
          join nairobi_entrants gb on gb.id = g.entrant2_id
          where g.event_id = ae.id and g.status = 'scheduled' and g.id <> m2.id and not g.held
            and (g.court is not null or g.play_order < m2.play_order)
            and (string_to_array(ga.name, ' & ') || string_to_array(gb.name, ' & '))
                && (string_to_array(ea.name, ' & ') || string_to_array(eb.name, ' & ')))
      order by m2.play_order, m2.id
    loop
      exit when array_length(a_free, 1) is null;
      chosen := a_free[1];
      update nairobi_matches set court = chosen, postponed = false, held = false, called_at = now(), called_ack = false, updated_at = now()
      where id = rec.id;
      a_free := a_free[2:];
    end loop;
  end loop;
end;
$$;

-- Admin: place a specific waiting match onto a specific free court by hand,
-- overriding the automatic pool. Other free courts still fill automatically.
create or replace function nairobi_admin_assign_court(p_pin text, p_match_id uuid, p_court int)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  total int;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- numeric-guarded: a malformed value fails open to 4 rather than aborting
  -- every mutating RPC that runs through here
  select case when coalesce(settings ->> 'courts', '') ~ '^[0-9]+$'
              then (settings ->> 'courts')::int else 4 end
  into total from nairobi_tournaments limit 1;
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' or m.court is not null then return 'That match is not waiting for a court.'; end if;
  if m.held then return 'That match is held. Put it back in the queue first.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'This match''s teams are not set yet.'; end if;
  if p_court < 1 or p_court > total then return 'No such court.'; end if;
  -- Never call a PERSON who is mid-game on another court. By player name, the
  -- same test the assigner uses: someone entered in two events has a separate
  -- entrant row in each, so the old id-level test never fired for them and the
  -- desk's manual placement put one human on two courts at once.
  if exists (
    select 1 from nairobi_matches oc
    join nairobi_entrants b1 on b1.id = oc.entrant1_id
    join nairobi_entrants b2 on b2.id = oc.entrant2_id
    join nairobi_entrants a1 on a1.id = m.entrant1_id
    join nairobi_entrants a2 on a2.id = m.entrant2_id
    where oc.status = 'scheduled' and oc.court is not null and oc.id <> m.id
      and (string_to_array(b1.name, ' & ') || string_to_array(b2.name, ' & '))
          && (string_to_array(a1.name, ' & ') || string_to_array(a2.name, ' & '))
  ) then
    return 'That team is already mid-game on another court.';
  end if;
  -- Same pool rule as nairobi_assign_courts: an Americano match holding court 1
  -- does not make the main draw's court 1 busy, and without this test the desk
  -- was told a genuinely free court had just been filled, with no way through.
  if exists (select 1 from nairobi_matches mm
             join nairobi_events me on me.id = mm.event_id
             where mm.status = 'scheduled' and mm.court = p_court
               and coalesce(me.settings ->> 'format', '') <> 'americano') then
    return 'Court ' || p_court || ' was just filled. Pick another.';
  end if;
  update nairobi_matches
  set court = p_court, postponed = false, held = false, called_at = now(), called_ack = false, updated_at = now()
  where id = p_match_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;
grant execute on function nairobi_admin_assign_court(text, uuid, int) to anon, authenticated;

-- The old up/down nudge function is gone: the app moved to
-- nairobi_admin_move_match, and this was the one queue mutator without the
-- advisory lock. The drop keeps older installs from carrying it.
drop function if exists nairobi_admin_reorder_match(text, uuid, text);

-- Admin: drop a waiting match directly in front of another one in its own
-- event's queue (p_before_id null sends it to the back). This is what the drag
-- handle on the Courts tab calls. play_order is numeric, so slotting between
-- two neighbours is just their midpoint: no other row is renumbered, and there
-- is no fixed step size to exhaust however many times the queue is rearranged.
create or replace function nairobi_admin_move_match(p_pin text, p_match_id uuid, p_before_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  t nairobi_matches;
  prev numeric;
  target numeric;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' or m.court is not null then return 'That match is not waiting in the queue.'; end if;

  -- Span every scheduled match of the event, including ones already on a court.
  -- Those still hold play_order values, so ignoring them lets the new position
  -- land exactly on one and reintroduce the collision this is meant to avoid.
  if p_before_id is null then
    select coalesce(max(play_order), m.play_order) + 10 into target
    from nairobi_matches
    where event_id = m.event_id and status = 'scheduled' and id <> m.id;
  else
    select * into t from nairobi_matches where id = p_before_id;
    if not found then return 'That spot is gone; try again.'; end if;
    if t.event_id <> m.event_id then return 'A match can only move within its own event.'; end if;
    if t.status <> 'scheduled' or t.court is not null then return 'That spot is gone; try again.'; end if;
    select max(play_order) into prev
    from nairobi_matches
    where event_id = m.event_id and status = 'scheduled'
      and id <> m.id and play_order < t.play_order;
    target := case when prev is null then t.play_order - 10 else (prev + t.play_order) / 2 end;
  end if;

  -- moving a match is a re-queue: it is no longer "postponed"
  update nairobi_matches set play_order = target, postponed = false, held = false, updated_at = now() where id = m.id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;
grant execute on function nairobi_admin_move_match(text, uuid, uuid) to anon, authenticated;

-- Admin: pull an on-court match off and bring a specific chosen match on in
-- its place (the "bring someone else on" path). The pulled match goes to the
-- front of its event's queue.
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
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into offm from nairobi_matches where id = p_off_match for update;
  if not found then return 'Match not found.'; end if;
  if offm.status <> 'scheduled' or offm.court is null then return 'That match is not on a court.'; end if;
  select * into onm from nairobi_matches where id = p_on_match for update;
  if not found then return 'The match to bring on was not found.'; end if;
  if onm.status <> 'scheduled' or onm.court is not null then return 'That match is not waiting for a court.'; end if;
  if onm.held then return 'That match is held. Put it back in the queue first.'; end if;
  if onm.entrant1_id is null or onm.entrant2_id is null then return 'That match''s teams are not set yet.'; end if;
  -- Americano matches live in their own court pool; swapping one off (or on)
  -- would cross the pools and double-book a court number.
  if exists (select 1 from nairobi_events e where e.id in (offm.event_id, onm.event_id)
             and coalesce(e.settings ->> 'format', '') = 'americano') then
    return 'Americano rounds rotate on their own; enter the score or pause the event instead.';
  end if;
  -- Never call a PERSON who is mid-game on another court (the match being
  -- taken off does not count: its players are the ones leaving). By player
  -- name, the same test the assigner uses, so a double-entered human cannot
  -- be hand-placed onto two courts.
  if exists (
    select 1 from nairobi_matches oc
    join nairobi_entrants b1 on b1.id = oc.entrant1_id
    join nairobi_entrants b2 on b2.id = oc.entrant2_id
    join nairobi_entrants a1 on a1.id = onm.entrant1_id
    join nairobi_entrants a2 on a2.id = onm.entrant2_id
    where oc.status = 'scheduled' and oc.court is not null and oc.id <> p_off_match
      and (string_to_array(b1.name, ' & ') || string_to_array(b2.name, ' & '))
          && (string_to_array(a1.name, ' & ') || string_to_array(a2.name, ' & '))
  ) then
    return 'That team is already mid-game on another court.';
  end if;
  c := offm.court;
  update nairobi_matches
  set court = c, postponed = false, held = false, called_at = now(), called_ack = false, updated_at = now()
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

-- Internal: validate and normalize a score. Returns error text, or null and
-- sets out params. Games format: [[a,b],[a,b],...].
create or replace function nairobi_check_score(
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
  wb2 boolean;
  is_am boolean;
begin
  pts := nairobi_ev_int_setting(p_event_id, case when p_stage = 'knockout' then 'points_to_knockout' else 'points_to_group' end,
                                case when p_stage = 'knockout' then 11 else 15 end);
  bo := nairobi_ev_int_setting(p_event_id, case when p_stage = 'knockout' then 'best_of_knockout' else 'best_of_group' end,
                               case when p_stage = 'knockout' then 3 else 1 end);
  -- Knockout games are always win-by-2; the setting governs only the group stage.
  wb2 := p_stage = 'knockout' or nairobi_ev_bool_setting(p_event_id, 'win_by_two', false);
  -- Americano is rally-scored: one game whose two scores add up to the points
  -- target exactly (15), nothing more, nothing less. An odd total cannot tie.
  is_am := coalesce((select e.settings ->> 'format' from nairobi_events e where e.id = p_event_id), '') = 'americano';

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
        if wb2 then
          if greatest(a, b) < pts then o_err := 'The winner needs at least ' || pts || ' points.'; return; end if;
          if greatest(a, b) - least(a, b) < 2 then o_err := 'The winner has to lead by 2.'; return; end if;
          if greatest(a, b) > pts and greatest(a, b) - least(a, b) > 2 then
            o_err := 'Past ' || pts || ', the game ends as soon as someone leads by 2.'; return;
          end if;
        else
          if greatest(a, b) <> pts then o_err := 'The winner needs exactly ' || pts || ' points.'; return; end if;
          if least(a, b) >= pts then o_err := 'The losing score must be under ' || pts || '.'; return; end if;
        end if;
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
      if is_am then
        if p_score1 + p_score2 <> pts then
          o_err := 'Americano: the two scores must add up to ' || pts || '.';
        end if;
      elsif wb2 then
        if greatest(p_score1, p_score2) < pts then o_err := 'The winner needs at least ' || pts || ' points.'; end if;
        if o_err is null and greatest(p_score1, p_score2) - least(p_score1, p_score2) < 2 then
          o_err := 'The winner has to lead by 2.';
        end if;
        if o_err is null and greatest(p_score1, p_score2) > pts
           and greatest(p_score1, p_score2) - least(p_score1, p_score2) > 2 then
          o_err := 'Past ' || pts || ', the game ends as soon as someone leads by 2.';
        end if;
      else
        if greatest(p_score1, p_score2) <> pts then o_err := 'The winner needs exactly ' || pts || ' points.'; end if;
        if o_err is null and least(p_score1, p_score2) >= pts then o_err := 'The losing score must be under ' || pts || '.'; end if;
      end if;
    end if;
    if o_err is null then
      o_score1 := p_score1; o_score2 := p_score2; o_games := null;
    end if;
  end if;
end;
$$;

-- ---------- score history helpers ----------

-- How a score reads on one line: "21-15", or "11-5, 9-11, 11-7" for best-of.
-- Null when the match has no score, which is what makes a first entry show as
-- an entry rather than a change.
create or replace function nairobi_score_text(m nairobi_matches)
returns text
language sql stable security definer set search_path = public
as $$
  select case
    when m.status <> 'played' or m.score1 is null then null
    -- the winner's name is part of the text on purpose: flipping a walkover to
    -- the other team must read as a change, or the score log skips the line
    when m.walkover then 'walkover · ' || coalesce(
      (select en.name from nairobi_entrants en
       where en.id = case when m.score1 > m.score2 then m.entrant1_id else m.entrant2_id end), '?')
    when m.games is not null and jsonb_typeof(m.games) = 'array' and jsonb_array_length(m.games) > 0
      then (select string_agg((g ->> 0) || '-' || (g ->> 1), ', ')
            from jsonb_array_elements(m.games) with ordinality t(g, i))
    else m.score1 || '-' || m.score2
  end;
$$;

-- Only a real change is worth a line. A save that lands the same score as
-- before is not a correction and would just add noise to the match everyone is
-- already looking at.
create or replace function nairobi_log_score(p_match_id uuid, p_action text, p_from text, p_to text, p_by_desk boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_from is not distinct from p_to then return; end if;
  insert into nairobi_match_log (match_id, action, from_text, to_text, by_desk)
  values (p_match_id, p_action, p_from, p_to, coalesce(p_by_desk, false));
end;
$$;

-- ---------- public score entry (first entry only, on-court matches only) ----------

create or replace function nairobi_submit_score(p_match_id uuid, p_score1 int, p_score2 int, p_games jsonb default null)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  chk record;
  v_courts int;
  v_recent int;
begin
  -- Advisory lock BEFORE any row lock: this function locks match rows and
  -- then reaches the same advisory lock inside nairobi_assign_courts, so
  -- taking it up front is what keeps the order total across every mutator.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status = 'played' then return 'A score is already in. Ask the desk to change it.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;
  if m.court is null then return 'This match is not on a court yet. Scores are entered from the Courts tab once it is called; otherwise ask the desk.'; end if;

  -- The desk can switch player entry off for the rest of the day and take
  -- every result at the table instead.
  if exists (select 1 from nairobi_tournaments
             where coalesce(settings ->> 'player_scores', 'true') = 'false') then
    return 'The desk is entering all scores today. Please report your result at the desk.';
  end if;

  -- A result can only come from a match on a court, and there are only so many
  -- courts, and a game takes longer than five minutes to play. So more entries
  -- than there are courts inside five minutes is nobody finishing a match: it
  -- is somebody working down the board for fun. Only successful public entries
  -- count, the desk is never counted and never blocked, and the window slides
  -- so a genuine backlog clears itself within minutes.
  select case when coalesce(settings ->> 'courts', '') ~ '^[0-9]+$'
              then (settings ->> 'courts')::int else 4 end
    into v_courts from nairobi_tournaments limit 1;
  select count(*) into v_recent from nairobi_match_log
   where not by_desk and action = 'score' and at > now() - interval '5 minutes';
  if v_recent >= greatest(4, coalesce(v_courts, 4)) then
    return 'That is more scores than the courts can have finished. Wait a few minutes or ask the desk to enter it.';
  end if;

  select * into chk from nairobi_check_score(m.event_id, m.stage, p_score1, p_score2, p_games, false);
  if chk.o_err is not null then return chk.o_err; end if;

  update nairobi_matches
  set score1 = chk.o_score1, score2 = chk.o_score2, games = chk.o_games,
      status = 'played', postponed = false, held = false, court = null,
      walkover = false, retired = null, updated_at = now()
  where id = p_match_id;

  perform nairobi_log_score(p_match_id, 'score', nairobi_score_text(m),
                            nairobi_score_text((select x from nairobi_matches x where x.id = p_match_id)), false);
  perform nairobi_advance_winner(p_match_id);
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- ---------- admin functions ----------

-- Old signature dropped so the added p_had_score default cannot create an
-- ambiguous overload for clients still calling with six named arguments.
drop function if exists nairobi_admin_submit_score(text, uuid, int, int, jsonb, boolean);
create or replace function nairobi_admin_submit_score(p_pin text, p_match_id uuid, p_score1 int, p_score2 int, p_games jsonb default null, p_walkover boolean default false, p_had_score boolean default null)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  nm nairobi_matches;
  chk record;
  old_w uuid;
  new_w uuid;
  v_s1 int;
  v_s2 int;
  v_games jsonb;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock: this function locks match rows and
  -- then reaches the same advisory lock inside nairobi_assign_courts, so
  -- taking it up front is what keeps the order total across every mutator.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;
  -- The saving screen believed the match was unscored, but a score landed
  -- meanwhile: refuse rather than silently overwrite someone's fresh entry.
  if p_had_score = false and m.status = 'played' then
    return 'A score just came in for this match; close and reopen it before changing anything.';
  end if;
  -- A retirement is a recorded outcome, not a normal score: the stored games
  -- are partial, so a blind re-save would re-derive the winner from them and
  -- can flip the match to the player who retired. Corrections go through
  -- Clear score first.
  if m.retired is not null then
    return 'This match ended by retirement. Clear the score first if it needs changing.';
  end if;
  old_w := case when m.status = 'played' and m.score1 > m.score2 then m.entrant1_id
                when m.status = 'played' then m.entrant2_id else null end;

  if coalesce(p_walkover, false) then
    if p_score1 is null or p_score2 is null or p_score1 = p_score2
       or p_score1 < 0 or p_score2 < 0 then return 'Bad walkover score.'; end if;
    v_s1 := p_score1; v_s2 := p_score2; v_games := null;
  else
    select * into chk from nairobi_check_score(m.event_id, m.stage, p_score1, p_score2, p_games, true);
    if chk.o_err is not null then return chk.o_err; end if;
    v_s1 := chk.o_score1; v_s2 := chk.o_score2; v_games := chk.o_games;
  end if;

  new_w := case when v_s1 > v_s2 then m.entrant1_id else m.entrant2_id end;
  -- Same reasoning as the next round: if the third-place match has been played
  -- off this semifinal's loser, flipping the loser here would leave the bronze
  -- sitting on a result that no longer happened.
  if m.loser_match_id is not null then
    select * into nm from nairobi_matches where id = m.loser_match_id for update;
    if found and nm.status = 'played' then
      if (case when m.loser_slot = 1 then nm.entrant1_id else nm.entrant2_id end)
         is distinct from (case when v_s1 > v_s2 then m.entrant2_id else m.entrant1_id end) then
        return 'The third place match already has a score. Clear it first.';
      end if;
    end if;
  end if;
  if m.next_match_id is not null then
    -- locked read: the winner-flip guard must not race a concurrent score on
    -- the next match, and refuse only when the played next round actually
    -- used a different team in this feeder's slot (a manually pre-filled and
    -- played later round with the same winner must not block the feeder).
    select * into nm from nairobi_matches where id = m.next_match_id for update;
    if found and nm.status = 'played' then
      if (case when m.next_slot = 1 then nm.entrant1_id else nm.entrant2_id end)
         is distinct from new_w then
        return 'The next round already has a score. Clear it first.';
      end if;
    end if;
  end if;

  update nairobi_matches
  set score1 = v_s1, score2 = v_s2, games = v_games,
      status = 'played', postponed = false, court = null, held = false,
      walkover = coalesce(p_walkover, false), retired = null, updated_at = now()
  where id = p_match_id;

  perform nairobi_log_score(p_match_id,
                            case when coalesce(p_walkover, false) then 'walkover' else 'score' end,
                            nairobi_score_text(m),
                            nairobi_score_text((select x from nairobi_matches x where x.id = p_match_id)), true);
  perform nairobi_advance_winner(p_match_id, old_w);
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Dismiss the "go to court" banner for everyone: desk confirms players are on court.
-- The desk can take score entry back off the players entirely.
-- Whether finals and the third place match are being held for the last day.
-- Only the wind-down trigger reads it: with this on, a running event that has
-- nothing left but its final does not hold up the next batch.
create or replace function nairobi_admin_set_finals_sunday(p_pin text, p_on boolean)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  update nairobi_tournaments
  set settings = coalesce(settings, '{}'::jsonb)
                 || jsonb_build_object('finals_sunday', coalesce(p_on, true));
  return 'OK';
end;
$$;
grant execute on function nairobi_admin_set_finals_sunday(text, boolean) to anon, authenticated;

create or replace function nairobi_admin_set_player_scores(p_pin text, p_on boolean)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  update nairobi_tournaments
  set settings = coalesce(settings, '{}'::jsonb)
                 || jsonb_build_object('player_scores', coalesce(p_on, true));
  return 'OK';
end;
$$;

create or replace function nairobi_admin_ack_called(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  update nairobi_matches set called_ack = true, updated_at = now() where id = p_match_id;
  if not found then return 'Match not found.'; end if;
  return 'OK';
end;
$$;

-- Records a drawn lot (or any other entrant metadata) without touching names.
-- Used when the whole USA Pickleball tiebreak chain leaves teams level and the
-- desk has to draw for the last qualifying place.
create or replace function nairobi_admin_set_entrant_meta(p_pin text, p_entrant_id uuid, p_meta jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from nairobi_entrants where id = p_entrant_id) then return 'Team not found.'; end if;
  update nairobi_entrants set meta = coalesce(p_meta, '{}'::jsonb) where id = p_entrant_id;
  return 'OK';
end;
$$;

-- Takes a match off its court and holds it out of the queue until the desk
-- puts it back, for the case where one team is ready and the other is not.
-- Postponing only moves a match down the order, so with nothing else waiting
-- the assigner called the same match straight back on.
-- Lock order, as everywhere else: the match row first, then the advisory lock.
create or replace function nairobi_admin_hold(p_pin text, p_match_id uuid, p_held boolean)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches%rowtype;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status = 'played' then return 'That match already has a score.'; end if;
  update nairobi_matches
  set held = p_held,
      court = case when p_held then null else court end,
      called_at = case when p_held then null else called_at end,
      called_ack = case when p_held then false else called_ack end,
      updated_at = now()
  where id = p_match_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Move a postponed (or any unplayed) match to the front of its event's queue.
create or replace function nairobi_admin_play_next(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  front numeric;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' then return 'That match already has a score.'; end if;
  select coalesce(min(play_order), m.play_order) - 1 into front
  from nairobi_matches where event_id = m.event_id and status = 'scheduled' and id <> m.id;
  update nairobi_matches set play_order = front, postponed = false, held = false, updated_at = now() where id = p_match_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Take an on-court match off its court: the next match in line takes the
-- court immediately, and this one moves to the front of its event's queue.
create or replace function nairobi_admin_swap_out(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  repl uuid;
  front numeric;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' or m.court is null then return 'That match is not on a court.'; end if;
  -- Americano matches live in their own court pool; pulling one off here would
  -- hand its court number to a main-draw replacement and double-book.
  if exists (select 1 from nairobi_events e where e.id = m.event_id
             and coalesce(e.settings ->> 'format', '') = 'americano') then
    return 'Americano rounds rotate on their own; enter the score or pause the event instead.';
  end if;

  -- Pick the replacement with the same weighting nairobi_assign_courts uses, so
  -- "bring on the next in line" brings on the match the Up next board is
  -- actually showing as next. Ordering by position-within-event first would
  -- always pick the lowest sort_order event's front match, which starves every
  -- other running event whenever more than one is live.
  with pending0 as (
    select mm.id, e.sort_order, mm.play_order,
           row_number() over (partition by mm.event_id order by mm.play_order, mm.id) as rn,
           count(*) over (partition by mm.event_id) as ev_n,
           count(*) over () as total_n,
           dense_rank() over (order by mm.event_id) as dr
    from nairobi_matches mm
    join nairobi_events e on e.id = mm.event_id and e.active
    where mm.status = 'scheduled' and mm.court is null and not mm.held
      and mm.entrant1_id is not null and mm.entrant2_id is not null
      and mm.id <> p_match_id
      -- Never an Americano match: that pool is physically separate, and its
      -- court numbers overlap the main draw's, so without this test a vacated
      -- main court 1 or 2 passes the courts-restriction check below and pulls
      -- an Americano match on out of round order, leaving the main court free.
      and coalesce(e.settings ->> 'format', '') <> 'americano'
      -- never a team that is already mid-game on another court
      and not exists (
        select 1 from nairobi_matches oc
        join nairobi_events oe on oe.id = oc.event_id
        where oc.status = 'scheduled' and oc.court is not null and oc.id <> p_match_id
          and coalesce(oe.settings ->> 'format', '') <> 'americano'
          and (oc.entrant1_id in (mm.entrant1_id, mm.entrant2_id)
            or oc.entrant2_id in (mm.entrant1_id, mm.entrant2_id)))
      and (
        not (e.settings ? 'courts')
        or jsonb_typeof(e.settings -> 'courts') <> 'array'
        or jsonb_array_length(e.settings -> 'courts') = 0
        or m.court in (select (value)::int from jsonb_array_elements_text(e.settings -> 'courts') where value ~ '^[0-9]+$')
      )
  ), pending as (
    -- same 35% even / 65% by-remaining blend as nairobi_assign_courts
    select id, sort_order, play_order,
           ((rn - 1) + 0.5) / (0.35 * (total_n::numeric / max(dr) over ()) + 0.65 * ev_n) as frac
    from pending0
  )
  select id into repl from pending order by frac, sort_order, play_order, id limit 1;
  if repl is null then return 'No other match is waiting, so it stays on court.'; end if;

  update nairobi_matches
  set court = m.court, postponed = false, held = false, called_at = now(), called_ack = false, updated_at = now()
  where id = repl;

  select coalesce(min(play_order), m.play_order) - 1 into front
  from nairobi_matches
  where event_id = m.event_id and status = 'scheduled' and court is null and id <> p_match_id;

  update nairobi_matches
  set court = null, play_order = front, postponed = false, called_at = null, called_ack = false, updated_at = now()
  where id = p_match_id;
  return 'OK';
end;
$$;

create or replace function nairobi_admin_clear_score(p_pin text, p_match_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  nm nairobi_matches;
  lm nairobi_matches;
  v_w uuid;
  v_l uuid;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock: this function locks match rows and
  -- then reaches the same advisory lock inside nairobi_assign_courts, so
  -- taking it up front is what keeps the order total across every mutator.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;

  v_w := case when m.status = 'played' and m.score1 is not null and m.score1 > m.score2
              then m.entrant1_id
              when m.status = 'played' and m.score1 is not null then m.entrant2_id end;
  v_l := case when m.status = 'played' and m.score1 is not null and m.score1 > m.score2
              then m.entrant2_id
              when m.status = 'played' and m.score1 is not null then m.entrant1_id end;

  if m.next_match_id is not null then
    -- locked read: without it a concurrent score on the next match could land
    -- between this check and the slot write, leaving a played match with a
    -- nulled team. Only this feeder's own winner is pulled back; a manually
    -- substituted team in that slot stays put.
    select * into nm from nairobi_matches where id = m.next_match_id for update;
    if found and nm.status = 'played' then
      return 'The next round already has a score. Clear it first.';
    end if;
  end if;
  if m.loser_match_id is not null then
    select * into lm from nairobi_matches where id = m.loser_match_id for update;
    if found and lm.status = 'played' then
      return 'The third place match already has a score. Clear it first.';
    end if;
  end if;

  if m.next_match_id is not null and nm.id is not null and v_w is not null then
    if m.next_slot = 1 then
      update nairobi_matches set entrant1_id = null, updated_at = now()
      where id = nm.id and status = 'scheduled' and entrant1_id = v_w;
    else
      update nairobi_matches set entrant2_id = null, updated_at = now()
      where id = nm.id and status = 'scheduled' and entrant2_id = v_w;
    end if;
  end if;
  if m.loser_match_id is not null and lm.id is not null and v_l is not null then
    if m.loser_slot = 1 then
      update nairobi_matches set entrant1_id = null, updated_at = now()
      where id = lm.id and status = 'scheduled' and entrant1_id = v_l;
    else
      update nairobi_matches set entrant2_id = null, updated_at = now()
      where id = lm.id and status = 'scheduled' and entrant2_id = v_l;
    end if;
  end if;

  update nairobi_matches
  set score1 = null, score2 = null, games = null, walkover = false, retired = null,
      status = 'scheduled', court = null, held = false, updated_at = now()
  where id = p_match_id;

  perform nairobi_log_score(p_match_id, 'clear', nairobi_score_text(m), null, true);
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

create or replace function nairobi_admin_postpone(p_pin text, p_match_id uuid, p_to_end boolean)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  anchor numeric;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock. nairobi_assign_courts takes this lock
  -- and then updates match rows, so a mutator that grabbed a row first and
  -- reached for the advisory lock second could cross with it: one holds the
  -- advisory lock and wants a row, the other holds that row and wants the
  -- advisory lock. Advisory first everywhere is the only total order.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.status <> 'scheduled' then return 'That match already has a score.'; end if;

  if p_to_end then
    select coalesce(max(play_order), m.play_order) + 10 into anchor
    from nairobi_matches where event_id = m.event_id and status = 'scheduled' and id <> m.id;
  else
    -- Land halfway between the two neighbours rather than one above the lower
    -- one: play_order is numeric, so a midpoint never collides, while a fixed
    -- +1 slowly eats the gaps until two matches share a position.
    select (play_order + coalesce(lead(play_order) over (order by play_order), play_order + 20)) / 2 into anchor
    from nairobi_matches
    where event_id = m.event_id and status = 'scheduled' and id <> m.id and play_order > m.play_order
    order by play_order
    offset 7 limit 1;
    if anchor is null then
      select coalesce(max(play_order), m.play_order) + 10 into anchor
      from nairobi_matches where event_id = m.event_id and status = 'scheduled' and id <> m.id;
    end if;
  end if;

  update nairobi_matches set play_order = anchor, postponed = true, court = null, updated_at = now() where id = p_match_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

create or replace function nairobi_admin_update_event(p_pin text, p_event_id uuid, p_name text, p_settings jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Merge rather than replace, and let callers send only the keys they changed.
  -- Two admins editing one event (say a schedule note and the court list) would
  -- otherwise each write back the other's key from their own stale snapshot,
  -- so whoever saved second silently undid the first edit.
  update nairobi_events
  set name = coalesce(p_name, name),
      settings = settings || coalesce(p_settings, '{}'::jsonb)
  where id = p_event_id;
  if not found then return 'Event not found.'; end if;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

create or replace function nairobi_admin_set_active(p_pin text, p_event_id uuid, p_active boolean)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from nairobi_events where id = p_event_id) then return 'Event not found.'; end if;
  if p_active and not exists (select 1 from nairobi_matches where event_id = p_event_id) then
    return 'Draw groups first, then start the event.';
  end if;
  -- Stamping autostarted consumes any pending auto-start for the current
  -- start_time: a deliberately paused event must stay paused.
  update nairobi_events
  set active = p_active,
      settings = coalesce(settings, '{}'::jsonb) || '{"autostarted": true}'::jsonb
  where id = p_event_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Deleting a whole event was deliberately impossible for a long time, on the
-- grounds that nothing in a live tournament should be one tap from gone. It
-- exists now for clearing out test events, and the client asks the organiser
-- to type the event name first; hiding (settings.hidden) is the reversible
-- option for anything mid-tournament. Matches go before entrants because a
-- match references both.
create or replace function nairobi_admin_delete_event(p_pin text, p_event_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE the row deletes (same order rule as everywhere).
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  if not exists (select 1 from nairobi_events where id = p_event_id) then return 'Event not found.'; end if;
  delete from nairobi_matches where event_id = p_event_id;
  delete from nairobi_entrants where event_id = p_event_id;
  delete from nairobi_events where id = p_event_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Starting events one at a time means the first takes every free court and the
-- second waits for them to come back. This flips them all first and assigns
-- once, so nairobi_assign_courts splits the courts between them by weight.
create or replace function nairobi_admin_set_active_many(p_pin text, p_event_ids uuid[], p_active boolean)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  n int;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if p_event_ids is null or array_length(p_event_ids, 1) is null then return 'No events given.'; end if;
  -- Alias the unnest column: a bare `id` here binds to nairobi_matches.id, so
  -- the test read `event_id = nairobi_matches.id`, was never true, and every
  -- attempt to start events together was refused with a message that sent the
  -- desk to "Draw new groups", which wipes a roster.
  if p_active and exists (
    select 1 from unnest(p_event_ids) as x(id)
    where not exists (select 1 from nairobi_matches m where m.event_id = x.id)
  ) then
    return 'Draw groups first, then start the event.';
  end if;
  update nairobi_events
  set active = p_active,
      settings = coalesce(settings, '{}'::jsonb) || '{"autostarted": true}'::jsonb
  where id = any(p_event_ids);
  get diagnostics n = row_count;
  if n = 0 then return 'Event not found.'; end if;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Events with an admin-set start time turn themselves on an hour and a
-- quarter early, unless settings.autostart is false, so
-- the desk does not have to be watching the clock. Any phone's refresh calls
-- this (anon-safe: it only enacts the stored schedule). Fires once per set
-- start time: activation stamps settings.autostarted, manual Start/Pause also
-- stamps it, and saving a new start time from the admin panel writes
-- autostarted=false to re-arm. start_time is naive local time from the
-- admin's phone; the tournament runs in Nairobi, hence the fixed zone. The
-- 12-hour lower bound keeps long-past start times from ever firing.
--
-- An event whose start time comes round while another one is still playing
-- does start: the courts are shared, so the two mix in exactly as they do when
-- the desk starts them together by hand. What never auto-starts is an event
-- that has already been played in, which is what stops a multi-day event
-- resuming itself on day two off day one's start time.
--
-- One bad start_time used to take the whole tournament's auto-start with it:
-- the update is a single statement, so a value that passed the regex but failed
-- the cast aborted it for every event at once, and the catch-all below then
-- reported success. Casting inside its own handler turns that into one null row
-- instead of a silent tournament-wide outage.
create or replace function nairobi_ts_or_null(p_text text)
returns timestamptz
language plpgsql stable security definer set search_path = public
as $$
begin
  return (p_text::timestamp at time zone 'Africa/Nairobi');
exception when others then
  return null;
end;
$$;

create or replace function nairobi_autostart_due()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  n int;
  m int;
  v_left int;
  v_running int;
  v_sunday boolean;
  v_winding boolean;
begin
  -- Pass one: events that start on the clock.
  update nairobi_events e
  set active = true,
      settings = coalesce(e.settings, '{}'::jsonb) || '{"autostarted": true}'::jsonb
  where not e.active
    and coalesce(e.settings ->> 'autostarted', '') <> 'true'
    and coalesce(e.settings ->> 'hidden', '') <> 'true'
    and coalesce(e.settings ->> 'archived', '') <> 'true'
    and coalesce(e.settings ->> 'autostart', '') <> 'false'
    and coalesce(e.settings ->> 'start_time', '') <> ''
    and exists (select 1 from nairobi_matches mm where mm.event_id = e.id)
    -- Never restart an event that has already been played in. A multi-day event
    -- paused overnight must be resumed by hand: the desk decides when day two
    -- begins, and the stored start time belongs to day one.
    and not exists (select 1 from nairobi_matches m2
                    where m2.event_id = e.id and m2.status = 'played')
    -- An hour and a quarter before the printed start, so the first matches are
    -- already up and the board is worth reading when people walk in.
    and nairobi_ts_or_null(e.settings ->> 'start_time')
        between now() - interval '12 hours' and now() + interval '75 minutes';
  get diagnostics n = row_count;

  -- Pass two: events that refused the clock. They come on when the courts are
  -- about to free up rather than at a printed time, which is the only way a
  -- second batch does not land on top of a first that has not finished.
  select coalesce((settings ->> 'finals_sunday') is distinct from 'false', true)
    into v_sunday from nairobi_tournaments limit 1;

  select count(*) into v_running from nairobi_events e
   where e.active
     and coalesce(e.settings ->> 'hidden', '') <> 'true'
     and coalesce(e.settings ->> 'archived', '') <> 'true'
     and coalesce(e.settings ->> 'format', '') <> 'americano';

  -- What is left to play in whatever is running. Finals and the third place
  -- match are held back for the last day, so while that is the plan they are
  -- not what anybody is waiting on.
  select count(*) into v_left
    from nairobi_matches mm
    join nairobi_events ee on ee.id = mm.event_id
   where ee.active
     and coalesce(ee.settings ->> 'hidden', '') <> 'true'
     and coalesce(ee.settings ->> 'archived', '') <> 'true'
     and coalesce(ee.settings ->> 'format', '') <> 'americano'
     and mm.status <> 'played'
     and not (v_sunday and mm.stage = 'knockout'
              and (mm.bracket_round = 0
                   or mm.bracket_round = (select max(x.bracket_round) from nairobi_matches x
                                          where x.event_id = mm.event_id and x.stage = 'knockout')));

  v_winding := (v_running > 0 and v_left <= 3);
  if v_running = 0 or v_winding then
    update nairobi_events e
    set active = true,
        settings = coalesce(e.settings, '{}'::jsonb) || '{"autostarted": true}'::jsonb
    where not e.active
      and coalesce(e.settings ->> 'autostart', '') = 'false'
      and coalesce(e.settings ->> 'autostarted', '') <> 'true'
      and coalesce(e.settings ->> 'hidden', '') <> 'true'
      and coalesce(e.settings ->> 'archived', '') <> 'true'
      and coalesce(e.settings ->> 'start_time', '') <> ''
      and exists (select 1 from nairobi_matches mm where mm.event_id = e.id)
      and not exists (select 1 from nairobi_matches m2
                      where m2.event_id = e.id and m2.status = 'played')
      -- Not before the printed time, bar the same run-up the clock gets: the
      -- people in this batch were told an hour, and turning up to find their
      -- match already called and gone is worse than an idle court.
      and nairobi_ts_or_null(e.settings ->> 'start_time')
          between now() - interval '12 hours' and now() + interval '75 minutes'
      -- A desk-set hold stops the idle-courts case, but three matches to go in
      -- something actually running beats it: those courts are about to empty.
      and (v_winding
           or nairobi_ts_or_null(e.settings ->> 'delay_until') is null
           or nairobi_ts_or_null(e.settings ->> 'delay_until') <= now());
    get diagnostics m = row_count;
    n := n + m;
  end if;

  if n > 0 then perform nairobi_assign_courts(); end if;
exception when others then
  -- a malformed start_time must never break loading for every phone
  return;
end;
$$;
grant execute on function nairobi_autostart_due() to anon, authenticated;

-- Creates an event (null p_event_id) or wipes and rebuilds an existing one.
-- The server forces event_id on every row so a payload can never write into
-- another event.
-- The signature grew p_force, and create-or-replace cannot change a signature:
-- it would leave the old seven-argument overload behind and PostgREST would
-- refuse to choose between them.
drop function if exists nairobi_admin_replace_event(text, uuid, text, int, jsonb, jsonb, jsonb);
create or replace function nairobi_admin_replace_event(
  p_pin text, p_event_id uuid, p_name text, p_sort_order int,
  p_settings jsonb, p_entrants jsonb, p_matches jsonb, p_force boolean default false)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_tid uuid;
  v_eid uuid;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row write: this function deletes match rows and
  -- then reaches the same advisory lock inside nairobi_assign_courts, which
  -- without this line is exactly the AB-BA order the lock rule forbids.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select id into v_tid from nairobi_tournaments limit 1;
  if v_tid is null then return 'No tournament row. Re-run the schema.'; end if;

  if p_event_id is null then
    insert into nairobi_events (tournament_id, name, sort_order, settings)
    values (v_tid, p_name, coalesce(p_sort_order, 0), coalesce(p_settings, '{}'::jsonb))
    returning id into v_eid;
  else
    v_eid := p_event_id;
    -- A redraw rebuilds a division that has not started. Played or on-court
    -- matches mean it HAS started, and the deletes below would take results
    -- and their whole score history with them (the log cascades): refuse
    -- unless the desk confirmed that loss explicitly and the client passed
    -- the force flag. A stale phone can no longer wipe a live division.
    if not coalesce(p_force, false) and exists (
      select 1 from nairobi_matches
      where event_id = v_eid and (status = 'played' or court is not null)
    ) then
      return 'This event has played or on-court matches, so the redraw was not applied.';
    end if;
    update nairobi_events
    set name = coalesce(p_name, name),
        sort_order = coalesce(p_sort_order, sort_order),
        settings = coalesce(p_settings, settings),
        stage = 'group',
        active = false
    where id = v_eid;
    if not found then return 'Event not found.'; end if;
    delete from nairobi_matches where event_id = v_eid;
    delete from nairobi_entrants where event_id = v_eid;
  end if;

  insert into nairobi_entrants (id, event_id, name, group_name, seed, meta)
  select (x ->> 'id')::uuid, v_eid, x ->> 'name', x ->> 'group_name', (x ->> 'seed')::int,
         coalesce(x -> 'meta', '{}'::jsonb)
  from jsonb_array_elements(coalesce(p_entrants, '[]'::jsonb)) x;

  insert into nairobi_matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot, loser_match_id, loser_slot)
  select (x ->> 'id')::uuid, v_eid, coalesce(x ->> 'stage', 'group'), x ->> 'group_name',
         (x ->> 'round')::int, (x ->> 'bracket_round')::int, (x ->> 'bracket_pos')::int,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         (x ->> 'score1')::int, (x ->> 'score2')::int, x -> 'games',
         coalesce(x ->> 'status', 'scheduled'), (x ->> 'play_order')::numeric,
         coalesce((x ->> 'postponed')::boolean, false),
         null, (x ->> 'next_match_id')::uuid, (x ->> 'next_slot')::int,
         (x ->> 'loser_match_id')::uuid, (x ->> 'loser_slot')::int
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  perform nairobi_assign_courts();
  return 'OK:' || v_eid;
end;
$$;

create or replace function nairobi_admin_rename_entrant(p_pin text, p_entrant_id uuid, p_name text)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if length(coalesce(trim(p_name), '')) = 0 then return 'Name cannot be empty.'; end if;
  update nairobi_entrants set name = trim(p_name) where id = p_entrant_id;
  if not found then return 'Team not found.'; end if;
  return 'OK';
end;
$$;

create or replace function nairobi_admin_remove_entrant(p_pin text, p_entrant_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  e nairobi_entrants;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE the row deletes (same order rule as everywhere).
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into e from nairobi_entrants where id = p_entrant_id;
  if not found then return 'Team not found.'; end if;
  if exists (select 1 from nairobi_matches where stage = 'knockout' and (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id)) then
    return 'They are in the knockout bracket. Edit the bracket or reset it first.';
  end if;
  -- Never delete a match that is live on a court out from under its players.
  if exists (select 1 from nairobi_matches where (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id)
             and status = 'scheduled' and court is not null) then
    return 'That team''s match is on a court right now. Score it or take it off court first.';
  end if;
  delete from nairobi_matches where entrant1_id = p_entrant_id or entrant2_id = p_entrant_id;
  delete from nairobi_entrants where id = p_entrant_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Adds one entrant plus their client-built catch-up matches.
create or replace function nairobi_admin_add_entrant(p_pin text, p_event_id uuid, p_entrant jsonb, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from nairobi_events where id = p_event_id) then return 'Event not found.'; end if;

  insert into nairobi_entrants (id, event_id, name, group_name, seed, meta)
  values ((p_entrant ->> 'id')::uuid, p_event_id, p_entrant ->> 'name', p_entrant ->> 'group_name', (p_entrant ->> 'seed')::int,
          coalesce(p_entrant -> 'meta', '{}'::jsonb));

  insert into nairobi_matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot, loser_match_id, loser_slot)
  select (x ->> 'id')::uuid, p_event_id, coalesce(x ->> 'stage', 'group'), x ->> 'group_name',
         (x ->> 'round')::int, null, null,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         null, null, null, 'scheduled', (x ->> 'play_order')::numeric, false,
         null, null, null, null, null
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Move an entrant to another group: their group matches are replaced with
-- client-built catch-up matches against the new group's members.
create or replace function nairobi_admin_move_entrant(p_pin text, p_entrant_id uuid, p_group text, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  e nairobi_entrants;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE the row deletes (same order rule as everywhere).
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into e from nairobi_entrants where id = p_entrant_id;
  if not found then return 'Team not found.'; end if;
  if exists (select 1 from nairobi_matches where stage = 'knockout' and (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id)) then
    return 'They are in the knockout bracket. Edit the bracket or reset it first.';
  end if;
  -- Never delete a match that is live on a court out from under its players.
  if exists (select 1 from nairobi_matches where (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id)
             and status = 'scheduled' and court is not null) then
    return 'That team''s match is on a court right now. Score it or take it off court first.';
  end if;

  delete from nairobi_matches where stage = 'group' and (entrant1_id = p_entrant_id or entrant2_id = p_entrant_id);
  update nairobi_entrants set group_name = p_group where id = p_entrant_id;

  insert into nairobi_matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot, loser_match_id, loser_slot)
  select (x ->> 'id')::uuid, e.event_id, 'group', p_group,
         (x ->> 'round')::int, null, null,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         null, null, null, 'scheduled', (x ->> 'play_order')::numeric, false,
         null, null, null, null, null
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- Manual bracket fix: set either slot of an unplayed knockout match.
create or replace function nairobi_admin_set_bracket_teams(p_pin text, p_match_id uuid, p_entrant1_id uuid, p_entrant2_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE any row lock: this function locks match rows and
  -- then reaches the same advisory lock inside nairobi_assign_courts, so
  -- taking it up front is what keeps the order total across every mutator.
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.stage <> 'knockout' then return 'Only knockout matches can be edited here.'; end if;
  if m.status = 'played' then return 'This match already has a score. Clear it first.'; end if;
  if p_entrant1_id is not null and p_entrant1_id = p_entrant2_id then
    return 'A team cannot play itself.';
  end if;
  if exists (
    select 1 from nairobi_entrants e
    where e.id in (p_entrant1_id, p_entrant2_id) and e.event_id <> m.event_id
  ) then
    return 'Pick teams from this event.';
  end if;
  update nairobi_matches set entrant1_id = p_entrant1_id, entrant2_id = p_entrant2_id,
      -- a match with an emptied slot cannot be played: release its court and
      -- banner, or the board draws that court Free while every placement is
      -- refused with "was just filled"
      court = case when p_entrant1_id is null or p_entrant2_id is null then null else court end,
      called_at = case when p_entrant1_id is null or p_entrant2_id is null then null else called_at end,
      updated_at = now()
  where id = p_match_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- The client computes the seeded bracket rows; this validates the PIN,
-- replaces any existing knockout matches for the event, and flips its stage.
create or replace function nairobi_admin_generate_bracket(p_pin text, p_event_id uuid, p_matches jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE the row deletes: the trailing assign_courts otherwise
  -- reaches this lock after rows are already held (the banned AB-BA order).
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  if not exists (select 1 from nairobi_events where id = p_event_id) then return 'Event not found.'; end if;

  delete from nairobi_matches where event_id = p_event_id and stage = 'knockout';

  insert into nairobi_matches (id, event_id, stage, group_name, round, bracket_round, bracket_pos,
                       entrant1_id, entrant2_id, score1, score2, games, status, play_order, postponed,
                       court, next_match_id, next_slot, loser_match_id, loser_slot)
  select (x ->> 'id')::uuid, p_event_id, 'knockout', null,
         (x ->> 'round')::int, (x ->> 'bracket_round')::int, (x ->> 'bracket_pos')::int,
         (x ->> 'entrant1_id')::uuid, (x ->> 'entrant2_id')::uuid,
         (x ->> 'score1')::int, (x ->> 'score2')::int, null,
         coalesce(x ->> 'status', 'scheduled'), (x ->> 'play_order')::numeric, false,
         null, (x ->> 'next_match_id')::uuid, (x ->> 'next_slot')::int,
         (x ->> 'loser_match_id')::uuid, (x ->> 'loser_slot')::int
  from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x;

  update nairobi_events set stage = 'knockout' where id = p_event_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

create or replace function nairobi_admin_reset_bracket(p_pin text, p_event_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  -- Advisory lock BEFORE the row deletes (same order rule as everywhere).
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  if not exists (select 1 from nairobi_events where id = p_event_id) then return 'Event not found.'; end if;
  delete from nairobi_matches where event_id = p_event_id and stage = 'knockout';
  -- The flag rides on the event, server-side: a deliberate reset must not be
  -- undone seconds later by another phone's auto-draw, and the client's own
  -- follow-up write can fail on venue wifi.
  update nairobi_events
  set stage = 'group',
      settings = coalesce(settings, '{}'::jsonb) || '{"no_autobracket": true}'::jsonb
  where id = p_event_id;
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- ---------- retirement ----------
-- Somebody started the match and could not finish it. The rulebook answer, and
-- what a Tournament Planner export does: the completed games stand, the game in
-- progress is credited to the opponent, and the opponent takes the match.
-- Unlike a walkover the points are real, because they were really scored, so
-- nothing here is zeroed out of the standings.
--
-- The score is stored exactly as it stood, because that is the score that goes
-- to DUPR: a retirement is rated on what was actually played, not on a game
-- finished on paper by somebody who had already left the court.
--
-- Best of N is clean, because the games and the result live in separate
-- columns: `games` keeps what happened (11-5, 3-7) and the games-won columns
-- credit the opponent the match. Best of 1 has only the one pair of numbers to
-- carry both, so when the retiring side is the one ahead there is no way to
-- record the real score and the right winner at once; the opponent is given the
-- smallest score that wins rather than the full target, which is the least
-- distortion available.
create or replace function nairobi_admin_retire(p_pin text, p_match_id uuid, p_retiree_id uuid,
                                                p_score1 int default null, p_score2 int default null,
                                                p_games jsonb default null)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  m nairobi_matches;
  nm nairobi_matches;
  old_w uuid;
  win_slot int;
  pts int;
  bo int;
  need int;
  g jsonb;
  arr jsonb := '[]'::jsonb;
  a int; b int;
  w1 int := 0; w2 int := 0;
  v_s1 int; v_s2 int;
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  perform pg_advisory_xact_lock(hashtext('nairobi_courts'));
  select * into m from nairobi_matches where id = p_match_id for update;
  if not found then return 'Match not found.'; end if;
  if m.entrant1_id is null or m.entrant2_id is null then return 'Teams for this match are not decided yet.'; end if;
  if p_retiree_id is null or p_retiree_id not in (m.entrant1_id, m.entrant2_id) then
    return 'Say which team retired.';
  end if;
  -- Same rule as the re-save guard in nairobi_admin_submit_score: a recorded
  -- retirement is only ever changed by clearing it first.
  if m.retired is not null then
    return 'This match ended by retirement. Clear the score first if it needs changing.';
  end if;
  -- And the mirror image: a match with a normal score is corrected through
  -- Clear score, never overwritten by a retirement. A score that landed while
  -- the desk's modal sat open would otherwise vanish under the retirement
  -- without a trace (retire has no stale-screen flag of its own).
  if m.status = 'played' then
    return 'This match already has a score. Clear it first if it actually ended by retirement.';
  end if;
  win_slot := case when p_retiree_id = m.entrant1_id then 2 else 1 end;

  pts := nairobi_ev_int_setting(m.event_id, case when m.stage = 'knockout' then 'points_to_knockout' else 'points_to_group' end,
                                case when m.stage = 'knockout' then 11 else 15 end);
  bo := nairobi_ev_int_setting(m.event_id, case when m.stage = 'knockout' then 'best_of_knockout' else 'best_of_group' end,
                               case when m.stage = 'knockout' then 3 else 1 end);

  if bo > 1 then
    need := bo / 2 + 1;
    if p_games is null or jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) = 0 then
      return 'Enter the games that were played before the retirement.';
    end if;
    if jsonb_array_length(p_games) > bo then return 'Best of ' || bo || ': that is too many games.'; end if;
    for g in select * from jsonb_array_elements(p_games) loop
      begin
        a := (g ->> 0)::int; b := (g ->> 1)::int;
      exception when others then
        return 'Enter both scores as whole numbers.';
      end;
      if a is null or b is null or a < 0 or b < 0 then return 'Enter both scores as whole numbers.'; end if;
      arr := arr || jsonb_build_array(jsonb_build_array(a, b));
      if a > b then w1 := w1 + 1; elsif b > a then w2 := w2 + 1; end if;
    end loop;
    -- The games stay exactly as they were played, including the one that was
    -- interrupted. Only the games-won columns are credited, so the opponent
    -- takes the match without a single point being invented.
    if win_slot = 1 then v_s1 := greatest(w1, need); v_s2 := least(w2, v_s1 - 1);
    else v_s2 := greatest(w2, need); v_s1 := least(w1, v_s2 - 1); end if;
  else
    if p_score1 is null or p_score2 is null or p_score1 < 0 or p_score2 < 0 then
      return 'Enter the score as it stood when they retired.';
    end if;
    arr := null;
    v_s1 := p_score1; v_s2 := p_score2;
    -- One game, one pair of numbers, and they have to name the winner as well
    -- as the score. Untouched whenever the opponent was already ahead, which is
    -- the ordinary case; otherwise the smallest score that wins.
    if win_slot = 1 and v_s1 <= v_s2 then v_s1 := v_s2 + 1; end if;
    if win_slot = 2 and v_s2 <= v_s1 then v_s2 := v_s1 + 1; end if;
  end if;

  old_w := case when m.status = 'played' and m.score1 > m.score2 then m.entrant1_id
                when m.status = 'played' then m.entrant2_id else null end;

  if m.next_match_id is not null then
    select * into nm from nairobi_matches where id = m.next_match_id for update;
    if found and nm.status = 'played' then
      if (case when m.next_slot = 1 then nm.entrant1_id else nm.entrant2_id end)
         is distinct from (case when win_slot = 1 then m.entrant1_id else m.entrant2_id end) then
        return 'The next round already has a score. Clear it first.';
      end if;
    end if;
  end if;
  if m.loser_match_id is not null then
    select * into nm from nairobi_matches where id = m.loser_match_id for update;
    if found and nm.status = 'played' then
      if (case when m.loser_slot = 1 then nm.entrant1_id else nm.entrant2_id end)
         is distinct from (case when win_slot = 1 then m.entrant2_id else m.entrant1_id end) then
        return 'The third place match already has a score. Clear it first.';
      end if;
    end if;
  end if;

  update nairobi_matches
  set score1 = v_s1, score2 = v_s2, games = arr,
      status = 'played', postponed = false, court = null, held = false,
      walkover = false, retired = p_retiree_id, updated_at = now()
  where id = p_match_id;

  perform nairobi_log_score(p_match_id, 'retire', nairobi_score_text(m),
                            nairobi_score_text((select x from nairobi_matches x where x.id = p_match_id)), true);
  perform nairobi_advance_winner(p_match_id, old_w);
  perform nairobi_assign_courts();
  return 'OK';
end;
$$;

-- ---------- participants ----------
-- The roster of people, kept apart from the entrants who play a given event.
-- Both functions are the only way in: the table has no read policy and no
-- grants, so an unlocked admin panel is the only thing that ever sees a gender
-- or a DUPR id.

create or replace function nairobi_admin_list_participants(p_pin text)
returns setof nairobi_participants
language plpgsql stable security definer set search_path = public
as $$
begin
  -- A stale PIN raises rather than returning an empty set: ok-but-empty reads
  -- as a deleted roster on the desk, and the save that follows makes it true.
  if not nairobi_verify_pin(p_pin) then raise exception 'Wrong PIN.'; end if;
  return query select * from nairobi_participants order by sort_order nulls last, name;
end;
$$;

-- Save the whole roster in one go, which is what the grid on screen means. Rows
-- carry the ids they were loaded with, so a participant keeps their identity
-- (and their entries) across an edit. A row the payload leaves out is deleted
-- only when this desk had seen its latest version (p_seen): removing a row is
-- still how you delete someone, but another desk's newer additions survive.
-- The signature grew p_seen, and create-or-replace cannot change a signature:
-- the old two-argument overload has to go or PostgREST refuses to choose.
drop function if exists nairobi_admin_save_participants(text, jsonb);
create or replace function nairobi_admin_save_participants(p_pin text, p_rows jsonb, p_seen timestamptz default null)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  keep uuid[];
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return 'Nothing to save.'; end if;
  -- An empty save is never what a desk means: the tab paints blank rows while
  -- the real roster is still loading, and saving that blank screen used to
  -- delete everyone, with no backup anywhere to restore from.
  if not exists (
    select 1 from jsonb_array_elements(p_rows) x
    where btrim(coalesce(x ->> 'name', '')) <> ''
  ) then
    return 'The roster cannot be saved empty. Add at least one person first.';
  end if;
  -- One desk at a time through the delete-and-upsert. The roster has its own
  -- advisory key: this function never touches match rows, so it stays out of
  -- the courts lock order entirely.
  perform pg_advisory_xact_lock(hashtext('nairobi_participants'));

  select coalesce(array_agg((x ->> 'id')::uuid), '{}')
    into keep
  from jsonb_array_elements(p_rows) x
  where x ->> 'id' is not null;

  -- Two desks: a row this payload leaves out is deleted only when this desk
  -- had actually seen its latest version (p_seen is the newest updated_at its
  -- load returned). Anyone saved on another phone after that survives, so
  -- desks merge instead of silently deleting each other's people. A null
  -- p_seen (an old client) keeps the plain replace-all meaning.
  delete from nairobi_participants
  where not (id = any(keep))
    and (p_seen is null or updated_at <= p_seen);

  insert into nairobi_participants (id, name, gender, dupr_singles, dupr_doubles, dupr_id, entries, sort_order, updated_at)
  select coalesce((x ->> 'id')::uuid, gen_random_uuid()),
         btrim(x ->> 'name'),
         nullif(btrim(coalesce(x ->> 'gender', '')), ''),
         (x ->> 'dupr_singles')::numeric,
         (x ->> 'dupr_doubles')::numeric,
         nullif(btrim(coalesce(x ->> 'dupr_id', '')), ''),
         coalesce(x -> 'entries', '{}'::jsonb),
         (x ->> 'sort_order')::numeric,
         now()
  from jsonb_array_elements(p_rows) x
  where btrim(coalesce(x ->> 'name', '')) <> ''
  on conflict (id) do update
    set name = excluded.name,
        gender = excluded.gender,
        dupr_singles = excluded.dupr_singles,
        dupr_doubles = excluded.dupr_doubles,
        dupr_id = excluded.dupr_id,
        entries = excluded.entries,
        sort_order = excluded.sort_order,
        updated_at = now();

  return 'OK';
end;
$$;

-- The one window into the roster that needs no PIN, for the public Players
-- tab: names, which events each person is in, and the partner. Deliberately
-- NOT `returns setof nairobi_participants` — that shape would publish any
-- column added to the table later without anyone noticing. The entries map is
-- rebuilt key by key for the same reason, so a field stored alongside the
-- partner cannot ride out with it, and entries pointing at a hidden or
-- archived event are dropped the way the rest of the app drops them.
create or replace function nairobi_public_participants()
returns table(id uuid, name text, entries jsonb)
language sql stable security definer set search_path = public
as $$
  select p.id, p.name,
         coalesce((
           select jsonb_object_agg(e.k, jsonb_build_object('partner', coalesce(e.v ->> 'partner', '')))
             from jsonb_each(p.entries) as e(k, v)
             join nairobi_events ev on ev.id::text = e.k
            where coalesce((ev.settings ->> 'hidden')::boolean, false) = false
              and coalesce((ev.settings ->> 'archived')::boolean, false) = false
         ), '{}'::jsonb) as entries
    from nairobi_participants p
   order by p.sort_order nulls last, p.name;
$$;

-- ---------- permissions ----------

revoke execute on function nairobi_advance_winner(uuid, uuid) from public, anon, authenticated;
revoke execute on function nairobi_ts_or_null(text) from public, anon, authenticated;
revoke execute on function nairobi_score_text(nairobi_matches) from public, anon, authenticated;
revoke execute on function nairobi_log_score(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke execute on function nairobi_assign_courts() from public, anon, authenticated;
revoke execute on function nairobi_check_score(uuid, text, int, int, jsonb, boolean) from public, anon, authenticated;
revoke execute on function nairobi_ev_int_setting(uuid, text, int) from public, anon, authenticated;
revoke execute on function nairobi_ev_bool_setting(uuid, text, boolean) from public, anon, authenticated;

grant execute on function nairobi_verify_pin(text) to anon, authenticated;
grant execute on function nairobi_admin_set_player_scores(text, boolean) to anon, authenticated;
grant execute on function nairobi_change_admin_pin(text, text) to anon, authenticated;
grant execute on function nairobi_submit_score(uuid, int, int, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_submit_score(text, uuid, int, int, jsonb, boolean, boolean) to anon, authenticated;
grant execute on function nairobi_admin_clear_score(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_postpone(text, uuid, boolean) to anon, authenticated;
grant execute on function nairobi_admin_play_next(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_swap_out(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_ack_called(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_move_entrant(text, uuid, text, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_update_event(text, uuid, text, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_set_active(text, uuid, boolean) to anon, authenticated;
grant execute on function nairobi_admin_delete_event(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_set_active_many(text, uuid[], boolean) to anon, authenticated;
grant execute on function nairobi_admin_set_entrant_meta(text, uuid, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_hold(text, uuid, boolean) to anon, authenticated;
grant execute on function nairobi_admin_replace_event(text, uuid, text, int, jsonb, jsonb, jsonb, boolean) to anon, authenticated;
grant execute on function nairobi_admin_rename_entrant(text, uuid, text) to anon, authenticated;
grant execute on function nairobi_admin_remove_entrant(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_add_entrant(text, uuid, jsonb, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_set_bracket_teams(text, uuid, uuid, uuid) to anon, authenticated;
grant execute on function nairobi_admin_generate_bracket(text, uuid, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_reset_bracket(text, uuid) to anon, authenticated;
grant execute on function nairobi_admin_retire(text, uuid, uuid, int, int, jsonb) to anon, authenticated;
grant execute on function nairobi_admin_list_participants(text) to anon, authenticated;
-- No PIN on this one, by design: it is the public Players tab.
grant execute on function nairobi_public_participants() to anon, authenticated;
grant execute on function nairobi_admin_save_participants(text, jsonb, timestamptz) to anon, authenticated;

-- ---------- realtime ----------

do $$ begin
  alter publication supabase_realtime add table nairobi_matches;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table nairobi_entrants;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table nairobi_events;
exception when others then null; end $$;
-- Corrections have to reach the other phones the moment they happen: a match
-- whose score changed is exactly the one everybody is looking at.
do $$ begin
  alter publication supabase_realtime add table nairobi_match_log;
exception when others then null; end $$;
-- nairobi_tournaments is deliberately NOT published: its row carries the admin
-- PIN hash, and realtime would replay it to subscribers. See the revoke above.
-- nairobi_participants is not published either: it is desk-only, and realtime
-- replays whole rows regardless of who is listening.

-- Install-only helper: invents the first admin PIN and remembers it for the
-- rest of this session, so the insert below and the printout at the end of the
-- file agree on one value. Nothing stores the PIN in plaintext; once this
-- session ends the only record of it is the bcrypt hash and whatever the
-- installer wrote down.
create or replace function nairobi_seed_pin()
returns text
language plpgsql
as $$
declare
  p text;
begin
  p := nullif(current_setting('nairobi.seed_pin', true), '');
  if p is null then
    p := lpad((floor(random() * 1000000))::int::text, 6, '0');
    perform set_config('nairobi.seed_pin', p, false);
  end if;
  return p;
end;
$$;
revoke execute on function nairobi_seed_pin() from public, anon, authenticated;

-- ============================================================
-- FORGOT THE ADMIN PIN? Nobody can read it back: only a bcrypt hash is
-- stored, and the hash is not even readable through the public key. That is
-- the point, but it means there is no "remind me", only a reset.
--
-- You own this database, so you can always set a new one. Run this single
-- line in the SQL editor, with your own PIN in place of 246813:
--
--   update nairobi_tournaments set admin_pin_hash = crypt('246813', gen_salt('bf')) where id is not null;
--
-- It takes effect immediately, no redeploy. Anyone already unlocked on a
-- phone stays unlocked until that tab is closed, so if you are resetting
-- because the PIN leaked, tell the desk to close and reopen the page.
-- ============================================================

-- ---------- seed data ----------
-- The tournament row is created on the very first run with a randomly
-- generated admin PIN, which the last statement in this file prints once. No
-- default PIN is written down here, so nothing published in this repo can be
-- used to unlock a live tournament. Change it any time from the Admin tab.
-- The insert is guarded, so re-running this file never touches an existing PIN.

-- Clear first, so the printout at the end can only show a PIN that this run
-- actually created. Without this, running the file twice in one session would
-- redisplay the first run's PIN and tell you to write down a dead value.
select set_config('nairobi.seed_pin', '', false);

insert into nairobi_tournaments (name, admin_pin_hash)
select 'Nairobi Open 2026', crypt(nairobi_seed_pin(), gen_salt('bf'))
where not exists (select 1 from nairobi_tournaments);

-- All category events, ready to fill with entrants from the Admin tab.
-- Every group game runs to 15. Knockouts everywhere default to best of 3 to
-- 11, per the README.
-- win_by_two and from_participants have to be spelled out here, not left to
-- the column default: an event whose settings simply lack the key reads as
-- off, which is how a fresh install used to arrive with no win-by-2 in the
-- group stage and nothing to tick on the Participants tab.
insert into nairobi_events (tournament_id, name, sort_order, settings)
select t.id, v.name, v.ord,
  ('{"points_to_group": 15' ||
   ', "points_to_knockout": 11, "best_of_group": 1, "best_of_knockout": 3,' ||
   ' "win_by_two": true, "from_participants": true,' ||
   ' "advance_per_group": 2, "knockout_size": "auto", "group_size": 6, "schedule_note": ""}')::jsonb
from nairobi_tournaments t,
  (values
    ('Open Doubles (Men)', 0), ('Open Singles (Women)', 1), ('Open Singles (Men)', 2),
    ('Open Doubles (Women)', 3), ('Open Mixed Doubles', 4),
    ('Intermediate Singles (Men)', 5), ('Intermediate Singles (Women)', 6),
    ('Intermediate Doubles (Men)', 7), ('Intermediate Doubles (Women)', 8),
    ('Intermediate Mixed Doubles', 9),
    ('Masters Doubles (Men)', 10), ('Masters Doubles (Women)', 11), ('Masters Mixed Doubles', 12)
  ) as v(name, ord)
where not exists (select 1 from nairobi_events);

-- ---------- sanity check, and the admin PIN if this was a first install ----------
-- This is the last statement on purpose: its result is what the SQL editor
-- shows. On a first install the admin_pin column is the ONLY time the new PIN
-- is ever displayed, so write it down before closing the tab. On every later
-- run it just says the PIN was left alone.
select
  (select count(*) from nairobi_tournaments) as tournaments,
  (select count(*) from nairobi_events) as events,
  (select count(*) from nairobi_entrants) as entrants,
  (select count(*) from nairobi_matches) as matches,
  coalesce(
    nullif(current_setting('nairobi.seed_pin', true), '') || '  <-- WRITE THIS DOWN, it is shown once',
    'unchanged (a PIN was already set)'
  ) as admin_pin;

-- ---------- optional one-off: clear leftover per-event court locks ----------
-- Only needed on a database that still carries 'courts' locks from the old
-- per-event court system (symptom: a court sits idle while matches wait).
-- Do NOT run it blind: "Courts this event may use" is a real setting now, so
-- this also clears any restriction an admin set on purpose. Check first with
--   select name, settings -> 'courts' from nairobi_events where settings ? 'courts';
-- and only run the update if those restrictions are not ones you meant to set.
--
-- update nairobi_events set settings = settings - 'courts' where settings ? 'courts';
-- select nairobi_assign_courts();

-- ============================================================
-- CLEANUP (after the tournament, to remove everything from the
-- shared project): uncomment and run this block. It only touches
-- nairobi_ objects; the Dispatch app is unaffected.
-- ============================================================
-- drop function if exists nairobi_admin_reset_bracket(text, uuid);
-- drop function if exists nairobi_admin_generate_bracket(text, uuid, jsonb);
-- drop function if exists nairobi_admin_set_bracket_teams(text, uuid, uuid, uuid);
-- drop function if exists nairobi_admin_move_entrant(text, uuid, text, jsonb);
-- drop function if exists nairobi_admin_add_entrant(text, uuid, jsonb, jsonb);
-- drop function if exists nairobi_admin_remove_entrant(text, uuid);
-- drop function if exists nairobi_admin_rename_entrant(text, uuid, text);
-- drop function if exists nairobi_admin_replace_event(text, uuid, text, int, jsonb, jsonb, jsonb);
-- drop function if exists nairobi_admin_set_active(text, uuid, boolean);
-- drop function if exists nairobi_admin_update_event(text, uuid, text, jsonb);
-- drop function if exists nairobi_admin_postpone(text, uuid, boolean);
-- drop function if exists nairobi_admin_clear_score(text, uuid);
-- drop function if exists nairobi_admin_play_next(text, uuid);
-- drop function if exists nairobi_admin_swap_out(text, uuid);
-- drop function if exists nairobi_admin_ack_called(text, uuid);
-- drop function if exists nairobi_admin_submit_score(text, uuid, int, int, jsonb, boolean);
-- drop function if exists nairobi_submit_score(uuid, int, int, jsonb);
-- drop function if exists nairobi_check_score(uuid, text, int, int, jsonb, boolean);
-- drop function if exists nairobi_assign_courts();
-- drop function if exists nairobi_advance_winner(uuid, uuid);
-- drop function if exists nairobi_ev_int_setting(uuid, text, int);
-- drop function if exists nairobi_change_admin_pin(text, text);
-- drop function if exists nairobi_verify_pin(text);
-- drop table if exists nairobi_matches;
-- drop table if exists nairobi_entrants;
-- drop table if exists nairobi_events;
-- drop table if exists nairobi_tournaments;
