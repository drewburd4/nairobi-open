-- ============================================================
-- Nairobi Open: OPTIONAL SMS add-on ("you're on court" texts)
-- Run AFTER supabase-schema.sql, in the same (dispatch) project.
-- Safe to re-run.
--
-- What it does: the moment a match is assigned a court, a trigger
-- posts to the nairobi-sms Edge Function, which sends one SMS to
-- every phone number saved for the two teams (Africa's Talking,
-- roughly 1KSh per message).
--
-- Privacy: numbers live in nairobi_contacts, which has row level
-- security enabled and NO read policy, so unlike the rest of the
-- tournament data they are never visible through the public API.
-- Admin reads/writes go through PIN-checked functions only.
--
-- Setup (details in README, "SMS" section):
--   1. Run this file. Copy the sms_shared_secret it prints at the end.
--   2. Dashboard -> Edge Functions -> deploy sms-function.ts under the
--      exact name nairobi-sms, with "Verify JWT" turned OFF.
--   3. Function secrets: AT_USERNAME, AT_API_KEY, NAIROBI_SMS_SECRET.
--   4. Turn sending on:
--        update nairobi_private set value = 'on' where key = 'sms_enabled';
-- Sending stays OFF until step 4, so this file is safe to run early.
-- ============================================================

set search_path = public, extensions;

create extension if not exists pg_net with schema extensions;

-- ---------- tables (all private: RLS on, no policies) ----------

create table if not exists nairobi_contacts (
  entrant_id uuid primary key references nairobi_entrants(id) on delete cascade,
  phones text[] not null default '{}',
  updated_at timestamptz not null default now()
);

create table if not exists nairobi_sms_log (
  id uuid primary key default gen_random_uuid(),
  match_id uuid,
  recipients text[] not null,
  message text not null,
  status text not null default 'queued',
  provider_response text,
  created_at timestamptz not null default now()
);

create table if not exists nairobi_private (
  key text primary key,
  value text not null
);

alter table nairobi_contacts enable row level security;
alter table nairobi_sms_log enable row level security;
alter table nairobi_private enable row level security;

insert into nairobi_private (key, value) values ('sms_enabled', 'off')
on conflict (key) do nothing;
insert into nairobi_private (key, value)
select 'sms_secret', encode(gen_random_bytes(16), 'hex')
where not exists (select 1 from nairobi_private where key = 'sms_secret');

-- ---------- admin functions (PIN-checked) ----------

create or replace function nairobi_admin_set_contacts(p_pin text, p_entrant_id uuid, p_phones text[])
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return 'Wrong PIN.'; end if;
  if not exists (select 1 from nairobi_entrants where id = p_entrant_id) then return 'Team not found.'; end if;
  if p_phones is null or array_length(p_phones, 1) is null then
    delete from nairobi_contacts where entrant_id = p_entrant_id;
    return 'OK';
  end if;
  if array_length(p_phones, 1) > 4 then return 'At most 4 numbers per team.'; end if;
  if exists (select 1 from unnest(p_phones) ph where ph !~ '^\+[0-9]{10,14}$') then
    return 'Numbers must be international format, like +2547XXXXXXXX.';
  end if;
  insert into nairobi_contacts (entrant_id, phones, updated_at)
  values (p_entrant_id, p_phones, now())
  on conflict (entrant_id) do update set phones = excluded.phones, updated_at = now();
  return 'OK';
end;
$$;

create or replace function nairobi_admin_list_contacts(p_pin text)
returns table(entrant_id uuid, phones text[])
language plpgsql stable security definer set search_path = public
as $$
begin
  if not nairobi_verify_pin(p_pin) then return; end if;
  return query select c.entrant_id, c.phones from nairobi_contacts c;
end;
$$;

grant execute on function nairobi_admin_set_contacts(text, uuid, text[]) to anon, authenticated;
grant execute on function nairobi_admin_list_contacts(text) to anon, authenticated;

-- ---------- the trigger: court assigned -> post to the Edge Function ----------

create or replace function nairobi_notify_called()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_secret text;
  v_names text;
  v_msg text;
  v_to text[];
  v_log uuid;
begin
  if coalesce((select value from nairobi_private where key = 'sms_enabled'), 'off') <> 'on' then return new; end if;
  select value into v_secret from nairobi_private where key = 'sms_secret';
  if v_secret is null then return new; end if;

  select array_agg(distinct ph) into v_to
  from nairobi_contacts c, unnest(c.phones) ph
  where c.entrant_id in (new.entrant1_id, new.entrant2_id);
  if v_to is null or array_length(v_to, 1) is null then return new; end if;

  -- flood guard: never more than 20 sends queued per minute
  if (select count(*) from nairobi_sms_log where created_at > now() - interval '1 minute') >= 20 then return new; end if;

  select coalesce(e1.name, '?') || ' vs ' || coalesce(e2.name, '?') into v_names
  from (select 1) x
  left join nairobi_entrants e1 on e1.id = new.entrant1_id
  left join nairobi_entrants e2 on e2.id = new.entrant2_id;
  v_msg := 'Nairobi Open: you are on Court ' || new.court || ' now. ' || v_names || '.';

  insert into nairobi_sms_log (match_id, recipients, message)
  values (new.id, v_to, v_msg)
  returning id into v_log;

  perform net.http_post(
    url := 'https://cutiomcwgicdqfgbdsnc.supabase.co/functions/v1/nairobi-sms',
    body := jsonb_build_object('log_id', v_log, 'to', to_jsonb(v_to), 'message', v_msg),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-nairobi-secret', v_secret)
  );
  return new;
end;
$$;

revoke execute on function nairobi_notify_called() from public, anon, authenticated;

drop trigger if exists nairobi_matches_called_sms on nairobi_matches;
create trigger nairobi_matches_called_sms
after update of court on nairobi_matches
for each row
when (old.court is null and new.court is not null and new.status = 'scheduled')
execute function nairobi_notify_called();

-- ---------- sanity check (copy the secret into the function's secrets) ----------
select
  (select value from nairobi_private where key = 'sms_secret') as sms_shared_secret,
  (select value from nairobi_private where key = 'sms_enabled') as sms_enabled,
  (select count(*) from nairobi_contacts) as teams_with_numbers;

-- ============================================================
-- CLEANUP (removes the SMS add-on only; main schema untouched):
-- ============================================================
-- drop trigger if exists nairobi_matches_called_sms on nairobi_matches;
-- drop function if exists nairobi_notify_called();
-- drop function if exists nairobi_admin_list_contacts(text);
-- drop function if exists nairobi_admin_set_contacts(text, uuid, text[]);
-- drop table if exists nairobi_sms_log;
-- drop table if exists nairobi_contacts;
-- drop table if exists nairobi_private;
