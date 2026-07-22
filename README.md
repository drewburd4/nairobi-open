# Nairobi Open

A one-file tournament app: group stages, court assignments, public score entry, live standings, and knockout brackets. Built for phones at the courts.

- `index.html`: the whole app.
- `supabase-schema.sql`: database schema plus all server-side rules. Run once in the Supabase SQL editor.
- `supabase-testdata.sql`: the sample tournament data (generated). Run after the schema; re-run any time to reset the samples.
- `supabase-sms.sql` + `sms-function.ts`: the optional SMS add-on (see the SMS section).
- Live site: https://drewburd4.github.io/nairobi-open/ (GitHub repo: drewburd4/nairobi-open, deploys from `main`).

## Current status

**Wired to the Dispatch app's Supabase project (shared for now); two SQL files to run.** The free plan's project slots are used by duara and dispatch, so the tournament runs inside the dispatch project: every table and function is prefixed `nairobi_`, so nothing touches or collides with the Dispatch tables. The app has that project's URL and publishable key baked in. There is one live site for everyone, no separate demo mode.

Setup, in the **dispatch** project on supabase.com → SQL Editor:

1. Run all of `supabase-schema.sql` once. It creates the `nairobi_` tables, all the write rules, the 13 category events, and sets the admin PIN to 0727.
2. Run all of `supabase-testdata.sql`. It loads the sample tournament so there is something real to play with: Open Doubles (Men) with 50 teams and its pools fully played (ready to test "Confirm group stage finished" and the knockout), Open Singles (Women) mid-tournament holding all four courts with one postponed match, and small fields in the other 11 events. Re-run it any time to reset the samples.

Then refresh the site: everyone with the link sees the same sample tournament and every change syncs live. Unlock Admin with 0727 and change the PIN to something private (0727 is public in this repo). When real rosters arrive, replace each event's sample data from the Admin tab ("Start over with a new list"); the commented block at the top of `supabase-testdata.sql` wipes all sample data at once.

The key in `index.html` is Supabase's publishable key, designed to be public; every write rule is enforced in the database. After the tournament, the whole thing can be removed from the shared project with the cleanup block commented out at the bottom of `supabase-schema.sql` (it only drops `nairobi_` objects). Moving to a dedicated project later is the same schema file, minus the prefix expectations in `index.html` (ask Claude).

## How it works

- **Events.** All categories (Open/Intermediate/Masters, singles/doubles/mixed) are pre-created. Each has its own groups, formats, and bracket. Events are started and paused from Admin, so a 4-day schedule is just: start today's event(s), pause or finish them, start tomorrow's. Schedule notes (e.g. "Sat 9am") show players what runs when. Events cannot be deleted (by design; replacing a roster is "Start over with a new list").
- **Courts.** One shared pool: every free court automatically takes the next match from the cross-event queue, which alternates between running events. No per-event court booking, nothing to reallocate, and no court ever sits idle while any running event has matches waiting. When one event runs out (pools done, bracket not confirmed yet), the other event flows onto its courts by itself.
- **Queue.** Matches run in round order, group A first, so everyone plays match 1 before match 2 starts; knockout matches run in bracket order so both feeders of the same quarterfinal play close together. No-shows get postponed down the queue by an admin and stay visible in a Postponed list. An on-court match can also be swapped out ("Off court, up next"): the next match takes its court and it plays next.
- **Score entry.** Anyone with the link can enter a score, but only for a match that is currently on a court and has no score yet (winners report from the Courts tab). Everything else, including corrections, requires the admin PIN. Point targets, best-of formats, and the on-court rule are enforced server-side.
- **Formats.** Per event and per stage: games to N points, best of 1, 3, or 5. Best-of matches record each game's score.
- **Standings.** Wins, then head to head (two-way ties), then point difference, then points scored. Tap a team for its full schedule and results.
- **Knockout.** Set a bracket size (or Auto). Before the bracket exists, the Bracket tab shows a projected paper-style bracket by group position (A1 vs C2 and so on, no names), including "Best 3rd" wildcards used to fill the bracket so there are no byes; the connector lines show who the winner plays next. When pools wrap, Admin → "Confirm group stage finished". Unplayed bracket matches have an admin "Edit teams" link for manual fixes.
- **Score sanity.** Public entries must match the format exactly (winner exactly at the points target). Admin entries are free-form, but an off-format score asks for an explicit "save anyway" acknowledgement so typos don't slip through.
- **Export / DUPR.** Admin → "Export results" downloads a CSV per event (or all events): one row per played match, players split out of team names, one column pair per game, walkovers flagged. It is shaped to copy into DUPR's club "Import Matches via CSV" template; DUPR identifies people by DUPR ID, so collect each player's DUPR ID (or the email on their DUPR account) with the roster.

## Day-of cheat sheet (desk)

- Unlock Admin with the PIN once per device; it sticks for the session.
- Start the day's event(s) in Admin (just Start event; courts share automatically).
- No-show: Courts tab, Postpone. Players not ready on court: open the match, "Off court, up next". Wrong score: tap the match anywhere, fix or clear it.
- Roster problems: Admin team list (rename, remove, add with catch-up matches).
- Pools done: check the Bracket tab, then Admin → "Confirm group stage finished".
- End of day or event: Admin → Export results (CSV) for DUPR or records.
- Useful trick: keep one phone or laptop at the desk open to the Courts tab; it updates live and works as the announcement board.

## SMS: "you're on court" texts (built in, off until set up)

When a match is assigned a court, every phone number saved for its two teams gets a text via Africa's Talking (~1KSh each; account app name "Pickleball Tournament", username `pickleball`). Numbers live in a private table the public API cannot read; admins manage them per team with the ☎ button in the Admin team list (07... numbers are normalized to +254). The trigger fires only on the moment a court is assigned, so re-calls after a swap text again but nothing double-sends, and there is a 20-per-minute flood guard.

One-time setup, in this order:

1. Run `supabase-sms.sql` in the dispatch project's SQL editor (after the main schema). Copy the `sms_shared_secret` it prints.
2. Supabase dashboard → Edge Functions → deploy a new function named exactly `nairobi-sms`, paste in `sms-function.ts`, and turn OFF "Verify JWT" for it (the shared secret replaces it).
3. Set the function's secrets: `AT_USERNAME` = `pickleball`, `AT_API_KEY` = the API key from the Africa's Talking dashboard (it lives only there, never in this repo), `NAIROBI_SMS_SECRET` = the secret from step 1.
4. Top up Africa's Talking airtime (M-Pesa works).
5. Switch it on in the SQL editor: `update nairobi_private set value = 'on' where key = 'sms_enabled';` (set `'off'` to pause any time).
6. Save a number for a test team (Admin → team list → ☎), then put its match on a court.

Texts come from Africa's Talking's default shared sender; a branded sender name needs slow carrier registration and isn't worth it for one event. Sandbox testing: add secret `AT_API_HOST` = `https://api.sandbox.africastalking.com` with `AT_USERNAME` = `sandbox`. Fallback if SMS is off: the Courts tab updates live on every phone and the desk announces, which is what most local tournaments do anyway.

## Development

No build step. Open `index.html` in a browser; with the keys wired in it talks to the live database. Blanking the two keys at the top of the file gives a local, offline, non-syncing copy with built-in sample data (dev convenience only). `supabase-testdata.sql` is generated from the app's own mock data builder, so the seeded database matches that built-in sample exactly. Tournament logic (grouping, round robin, standings, seeding, brackets, court assignment) lives in a marked pure-logic script block that can be unit tested in node.
