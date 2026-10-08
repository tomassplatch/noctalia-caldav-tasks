# CalDAV Tasks Sync - Noctalia plugin

A to-do panel and bar widget for [Noctalia](https://noctalia.dev) v5 that syncs with a
CalDAV task calendar. Tested with **Nextcloud Tasks**.

- add and complete tasks
- tags (stored as iCalendar `CATEGORIES`) with suggestions from your existing tags
- due dates (date only, `YYYY-MM-DD`)
- an open-task counter in the bar

## Requirements
- Noctalia v5
- `python3`

## Install
```
noctalia msg plugins source add caldav-tasks git https://github.com/tomassplatch/noctalia-caldav-tasks.git
```
Then enable **CalDAV Tasks Sync** and fill in the plugin settings.

## Settings
| Setting | |
|---|---|
| Server URL | e.g. `https://cloud.example.com` |
| Username | |
| App password | Nextcloud: Settings → Security → *Devices & sessions* |
| Calendar name | the task list's name (matching is forgiving: case, spaces, partial) |
| Calendar URL | optional; if set, discovery is skipped and this exact calendar is used |

## How the calendar is found
1. the *Calendar URL* setting, if filled in;
2. Nextcloud's layout (`/remote.php/dav/calendars/<user>/`);
3. standard CalDAV discovery (`current-user-principal` → `calendar-home-set`), keeping only
   calendars that support tasks (`VTODO`).

Other CalDAV servers (Radicale, Baïkal, Synology, …) should work through 2–3 or via the
*Calendar URL* setting, but only Nextcloud has been tested by the author.
Google Calendar needs OAuth and is **not** supported.

## Safety
Edits are `GET` → change one property → `PUT`, and the `PUT` is conditional (`If-Match`), so a
change made in another app between two syncs is refused rather than overwritten. Your
credentials are only sent to the configured server, and never over a downgrade from https to http.

## Known limitations
- The app password is passed to a helper process as an argument, so other local users can see
  it in the process list while a sync runs. Use an app password, not your main password.
- Due dates are date-only; time of day is not editable.
- Recurring tasks are shown but not specially handled.

## Disclaimer
- This plugin is completely vibe-coded for my own needs. No guarantees.
