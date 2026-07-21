# Nairobi Open

A one-file tournament app: group stages, court assignments, public score entry, live standings, and knockout brackets. Built for phones at the courts.

- `index.html`: the whole app.
- `supabase-schema.sql`: database schema plus all server-side rules. Run once in the Supabase SQL editor.
- `supabase-testdata.sql`: the sample tournament data (generated). Run after the schema; re-run any time to reset the samples.
- Live site: https://drewburd4.github.io/nairobi-open/ (GitHub repo: drewburd4/nairobi-open, deploys from `main`).

## Current status

**Wired to the Dispatch app's Supabase project (shared for now); two SQL files to run.** The free plan's project slots are used by duara and dispatch, so the tournament runs inside the dispatch project: every table and function is prefixed `nairobi_`, so nothing touches or collides with the Dispatch tables. The app has that project's URL and publishable key baked in. There is one live site for everyone, no separate demo mode.

Setup, in the **dispatch** project on supabase.com → SQL Editor:

1. Run all of `supabase-schema.sql` once. It creates the `nairobi_` tables, all the write rules, the 13 category events, and sets the admin PIN to 0727.
2. Run all of `supabase-testdata.sql`. It loads the sample tournament so there is something real to play with: Open Doubles (Men) with 50 teams and its pools fully played (ready to test "Confirm group stage finished" and the knockout), Open Singles (Women) live on court 4 with one postponed match, and small fields in the other 11 events. Re-run it any time to reset the samples.

Then refresh the site: everyone with the link sees the same sample tournament and every change syncs live. Unlock Admin with 0727 and change the PIN to something private (0727 is public in this repo). When real rosters arrive, replace each event's sample data from the Admin tab ("Start over with a new list"); the commented block at the top of `supabase-testdata.sql` wipes all sample data at once.

The key in `index.html` is Supabase's publishable key, designed to be public; every write rule is enforced in the database. After the tournament, the whole thing can be removed from the shared project with the cleanup block commented out at the bottom of `supabase-schema.sql` (it only drops `nairobi_` objects). Moving to a dedicated project later is the same schema file, minus the prefix expectations in `index.html` (ask Claude).

## How it works

- **Events.** All categories (Open/Intermediate/Masters, singles/doubles/mixed) are pre-created. Each has its own groups, formats, and bracket. Events are started and paused from Admin, so a 4-day schedule is just: start today's event(s), pause or finish them, start tomorrow's. Schedule notes (e.g. "Sat 9am") show players what runs when.
- **Courts.** Each running event is allocated specific courts (checkboxes in Admin). The app assigns the next match in line to each free court automatically. Allocations can change mid-day and take effect immediately; two events can split the 4 courts.
- **Queue.** Matches run in round order, group A first, so everyone plays match 1 before match 2 starts. No-shows get postponed down the queue by an admin and stay visible in a Postponed list on the Courts tab.
- **Score entry.** Anyone with the link can enter a score, but only for a match that is currently on a court and has no score yet (winners report from the Courts tab). Everything else, including corrections, requires the admin PIN. Point targets, best-of formats, and the on-court rule are enforced server-side.
- **Formats.** Per event and per stage: games to N points, best of 1, 3, or 5. Best-of matches record each game's score.
- **Standings.** Wins, then head to head (two-way ties), then point difference, then points scored. Tap a team for its full schedule and results.
- **Knockout.** Set a bracket size (or Auto). Before the bracket exists, the Bracket tab shows a projected paper-style bracket by group position (A1 vs C2 and so on, no names), including "Best 3rd" wildcards used to fill the bracket so there are no byes; the connector lines show who the winner plays next. When pools wrap, Admin → "Confirm group stage finished". Unplayed bracket matches have an admin "Edit teams" link for manual fixes.

## Day-of cheat sheet (desk)

- Unlock Admin with the PIN once per device; it sticks for the session.
- Start the day's event(s) in Admin (pick courts + Start event).
- No-show: Courts tab, Postpone. Wrong score: tap the match anywhere, fix or clear it.
- Roster problems: Admin team list (rename, remove, add with catch-up matches).
- Pools done: check the Bracket tab seeding, then Admin → "Confirm group stage finished".
- Useful trick: keep one phone or laptop at the desk open to the Courts tab; it updates live and works as the announcement board.

## Possible add-on: notify players when they're on court

Not built yet; feasibility notes so the thinking is saved:

- **SMS (recommended if wanted).** Kenya-appropriate via Africa's Talking (or Twilio). Roughly 1KSh per message, so a few hundred shillings for the whole tournament. Needs: an Africa's Talking account, phone numbers collected with the roster, and a small Supabase Edge Function that fires when a match gets assigned a court. Real setup work (account approval, secrets), so allow a few days of lead time. Requires the Supabase setup above first.
- **Email.** Cheap and easy to send, but nobody checks email courtside. Not worth it.
- **Web push.** Free, works well on Android; on iPhones it only works if the person adds the site to their home screen first. Unreliable for a mixed crowd.
- **Zero-setup fallback.** The Courts tab already updates live on everyone's phone, and the desk announces. This is what most local tournaments do.

## Development

No build step. Open `index.html` in a browser; with the keys wired in it talks to the live database. Blanking the two keys at the top of the file gives a local, offline, non-syncing copy with built-in sample data (dev convenience only). `supabase-testdata.sql` is generated from the app's own mock data builder, so the seeded database matches that built-in sample exactly. Tournament logic (grouping, round robin, standings, seeding, brackets, court assignment) lives in a marked pure-logic script block that can be unit tested in node.
