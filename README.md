# Pickleball Tournament

A one-file tournament app: group stages, a live match queue, public score entry, standings, and knockout brackets. Built for phones at the courts.

- `index.html`: the whole app. With no Supabase keys it runs in demo mode with sample data.
- `supabase-schema.sql`: database schema plus all server-side rules. Run once in the Supabase SQL editor.

## How it works

- **Events.** A tournament holds multiple events (Men's Doubles, Men's Singles, ...) running concurrently. Each event has its own groups, point rules, and bracket. The court queue mixes all events.
- **Queue, not time slots.** Matches have a play order. The "Up next" tab shows the next matches in line for the courts. When a score comes in, the queue moves up. No-shows get postponed down the queue by an admin.
- **Score entry.** Anyone with the link can enter a score for a match that has no score yet. Changing an existing score requires the admin PIN. Rules like "first to 21" are enforced server-side, so the public API cannot be abused.
- **Standings.** Wins, then head to head (two-way ties), then point difference, then points scored. Group sizes can differ; cross-group seeding for the bracket uses win rate and average point difference.
- **Bracket.** Top N per group advance, seeded so group winners meet runners-up from other groups first. Byes auto-advance. Winners flow through the bracket as scores are entered.

## Going live (about 10 minutes)

1. Create a free project at supabase.com (a new organization if your free slots are used).
2. In the SQL editor, paste `supabase-schema.sql`. **Change the `CHANGE_ME` PIN near the bottom first.** Run it.
3. In Supabase: Project Settings, then API. Copy the project URL and the `anon` `public` key.
4. In `index.html`, paste both into `SUPABASE_URL` and `SUPABASE_ANON_KEY` at the top of the first script block.
5. Serve `index.html` anywhere static (GitHub Pages, Vercel, Netlify). For GitHub Pages: push this repo, then Settings, Pages, deploy from branch `main`, root folder.
6. Open the site, go to Admin, unlock with your PIN, and build your first event: paste entrants one per line, set the group size, Preview, then Build.

The anon key is designed to be public; all write rules live in the database functions.

## Day-of cheat sheet

- Share one link with everyone. Players find their matches on "Up next" or search the Schedule tab.
- Winners report scores by tapping their match.
- Someone missing? Admin: postpone the match (drops it about 8 spots) or send it to the end of the event's queue.
- Wrong score? Admin: open the match, fix it, or clear it back into the queue.
- Group play done (or done enough)? Admin: Generate bracket. Unplayed group matches just count as not played.
- Point targets and advance-per-group can be changed anytime in Admin. Group size changes require rebuilding the event (wipes that event's scores), so settle groups before play starts.

## Development

No build step. Open `index.html` in a browser: demo mode works offline. Tournament logic (grouping, round robin, queue weaving, standings, bracket seeding) lives in a marked pure-logic script block that can be unit tested in node.
