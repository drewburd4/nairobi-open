# Nairobi Open

A one-file tournament app: group stages, court assignments, public score entry, live standings, and knockout brackets. Built for phones at the courts.

- `index.html`: the whole app. With no Supabase keys it runs in demo mode with sample data (admin PIN 0727).
- `supabase-schema.sql`: database schema plus all server-side rules. Run once in the Supabase SQL editor.
- Live site: https://drewburd4.github.io/nairobi-open/ (GitHub repo: drewburd4/nairobi-open, deploys from `main`).

## Current status

**Not connected to a database yet.** The live link currently shows the demo with fake sample data. Nothing entered there is saved or shared: every phone gets its own throwaway copy that resets on refresh, and a banner says so. Do not share the link with players until the Supabase steps below are done.

## Supabase setup (do this before the tournament)

The free plan allows 2 active projects per organization, and both slots are used (duara, dispatch). Options, in order of preference:

1. **New free organization.** When creating the project, choose "New organization" and the Free plan. A fresh org normally comes with its own 2 free project slots, so this usually costs nothing. Try this first.
2. **Share the dispatch project.** If Supabase refuses a new free org, the tournament tables can live inside an existing project under a separate Postgres schema so nothing collides. This needs a reworked SQL file and a one-line app change: ask Claude to "set up the Nairobi Open schema for a shared Supabase project" and it will be adjusted.
3. **Pay for a month** of Pro (~$25) on a third project and cancel after the tournament. Fine, but options 1 and 2 should make it unnecessary.

Then:

1. In the new project: SQL Editor → paste all of `supabase-schema.sql` → Run. This is the only thing to run, once. It creates the tables, all the rules, the 13 category events, and sets the admin PIN to 0727.
2. Project Settings → API → copy the **Project URL** and the **anon public** key.
3. Paste them into `SUPABASE_URL` and `SUPABASE_ANON_KEY` at the top of the first `<script>` block in `index.html` (or hand them to Claude to wire in and verify).
4. Commit and push. GitHub Pages redeploys in about a minute.
5. Open the site, unlock Admin with 0727, and enter one test score to confirm it syncs. Then share the link.

The anon key is designed to be public; every write rule is enforced in the database.

## How it works

- **Events.** All categories (Open/Intermediate/Masters, singles/doubles/mixed) are pre-created. Each has its own groups, formats, and bracket. Events are started and paused from Admin, so a 4-day schedule is just: start today's event(s), pause or finish them, start tomorrow's. Schedule notes (e.g. "Sat 9am") show players what runs when.
- **Courts.** Each running event is allocated specific courts (checkboxes in Admin). The app assigns the next match in line to each free court automatically. Allocations can change mid-day and take effect immediately; two events can split the 4 courts.
- **Queue.** Matches run in round order, group A first, so everyone plays match 1 before match 2 starts. No-shows get postponed down the queue by an admin and stay visible in a Postponed list on the Courts tab.
- **Score entry.** Anyone with the link can enter a score for a match that has no score yet (winners report). Changing an existing score requires the admin PIN. Point targets and best-of formats are enforced server-side.
- **Formats.** Per event and per stage: games to N points, best of 1, 3, or 5. Best-of matches record each game's score.
- **Standings.** Wins, then head to head (two-way ties), then point difference, then points scored. Tap a team for its full schedule and results.
- **Knockout.** Set a bracket size (or Auto). The Bracket tab shows the projected seeding live, including "Best 3rd" wildcards used to fill the bracket so there are no byes. When pools wrap, Admin → "Confirm group stage finished". Unplayed bracket matches have an admin "Edit teams" link for manual fixes.

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

No build step. Open `index.html` in a browser: demo mode works offline. Tournament logic (grouping, round robin, standings, seeding, brackets, court assignment) lives in a marked pure-logic script block that can be unit tested in node.
