# Round Robin Scheduler (Web)

This project runs a small web app (Ruby WEBrick) that:
- Generates a round-robin schedule from your settings (courts, teams, refs, round length, start time).
- Previews the rounds in the browser.
- Downloads a CSV of the generated schedule.

## Run locally

```bash
ruby server.rb
```

Then open:

`http://127.0.0.1:4567`

## Settings

- `Teams`: Must be greater than the number of 'Matches per team'.
- `Courts`: number of parallel courts (simaltaneous possible games).
- `Peer reffing`: toggles peer ref assignment.
- `Ref slots per round`: how many courts per round get assigned to teams to ref (these come from the teams that are not playing).
- `Round length (minutes)`: duration of each slot.
- `Start time`: time the first round starts.
- `Ensure each team has at least one Bye`: if enabled, the generator will automatically increase the number of rounds (up to what’s feasible) so every team has at least one bye.

## CSV

After generating, click **Download CSV**.

CSV columns include:
- `Round`
- `Court nA`, `Court nB` for each court
- `Ref (c1-c2)` columns (only if refs are enabled)
- `Bye` (semicolon-separated team numbers for byes)

# round-robin-scheduler
