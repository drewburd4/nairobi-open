# Nairobi Open

A one-file tournament app: group stages, court assignments, public score entry, live standings, and knockout brackets. Built for phones at the courts.

- `index.html`: the whole app. With no Supabase keys it runs in demo mode with sample data (admin PIN 0218).
- `supabase-schema.sql`: database schema plus all server-side rules. Run once in the Supabase SQL editor.

## Going live

1. Create a free project at supabase.com.
2. Open the SQL editor, paste all of `supabase-schema.sql`, Run. (The PIN is 0218; the 13 category events are pre-created.)
3. Project Settings, then API: copy the Project URL and the `anon public` key.
4. Paste both into the two constants at the top of the first `<script>` block in `index.html`.
5. Push to GitHub. The site serves from GitHub Pages; share that one link with everyone.

## How it works

- **Events.** The tournament holds all categories (Open/Intermediate/Masters, singles/doubles/mixed). Each event has its own groups, formats, and bracket. Events are started and paused from Admin, so a 4-day schedule is just: start today's event(s), pause or finish them, start tomorrow's.
- **Courts.** Each running event is allocated specific courts (checkboxes in Admin). The app automatically assigns the next match in line to each free court. Allocations can be changed mid-day and take effect immediately; two events can split the 4 courts.
- **Queue.** Matches run in round order, group A first, so everyone plays match 1 before match 2 starts. No-shows get postponed down the queue by an admin and stay visible in a Postponed list.
- **Score entry.** Anyone with the link can enter a score for a match that has no score yet (winners report). Changing an existing score requires the admin PIN. Point targets and best-of formats are enforced server-side.
- **Formats.** Per event and per stage: games to N points, best of 1, 3, or 5. Best-of matches record each game's score.
- **Standings.** Wins, then head to head (two-way ties), then point difference, then points scored. Tap a team for its full schedule and results.
- **Knockout.** Set a bracket size (or Auto). The seeding preview on the Bracket tab shows exactly who is in, including "best 3rd place" wildcards used to fill the bracket, so there are no byes unless entrants run out. When group play wraps, the desk hits "Confirm group stage finished". Manual fixes: every unplayed bracket match has an admin "Edit teams" link.

## Day-of cheat sheet (desk)

- Unlock Admin with the PIN once per device; it sticks for the session.
- Start the day's event(s) in Admin (courts + Start event).
- No-show: Courts tab, Postpone. Wrong score: tap the match anywhere, fix or clear it.
- Roster problems: Admin team list (rename, remove, add with catch-up matches).
- Pools done: check the Bracket tab seeding, then Admin, "Confirm group stage finished".

## Development

No build step. Open `index.html` in a browser: demo mode works offline. Tournament logic (grouping, round robin, standings, seeding, brackets, court assignment) lives in a marked pure-logic script block that can be unit tested in node.
