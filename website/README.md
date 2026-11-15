# Cyber Circle Challenge website

Registration with the QR card and the scoreboard, hosted on the internet
(Django 5.2). The installation's control server syncs with it: it pulls the
registrations (card, name, age) and pushes the current event's scoreboard.
Email, postcode and place stay here and are erased after the event.

| Page | |
|---|---|
| `/` | welcome, how to join, the current event's top 10 |
| `/register/?id=<card>` | the QR card's link: register (or: already registered as ...) |
| `/scoreboard/`, `/scoreboard/<id>/` | the current / an earlier event (`?id=<card>`: your place): its days and hours, a bar per player (their rounds next to the best's), *Hoe ver kwam iedereen?* (how many players reached each number of rounds; in groups when the best got far; yours in teal); `.json` too |
| `/events/` | every event: its days, players, plays, the best, its top 3 |
| `/games/` | *De spellen*: how to join, a round, lives and the robot, the scoreboard, then every game with its rules and a picture. The rules are the installation's (its *Teksten*: the operator can change them; sent with the scoreboard, with the games not played at this event marked); until the first sync the game's own (`challenge/game_texts.py`). Pictures: `challenge/static/challenge/games/` (from `docs/gallery`) |
| `/how-it-works/`, `/privacy/` | |
| `/admin/` | events, registrations (CSV, winners with email, erase personal data) |
| `/api/health`, `/api/sync/...` | for the control server (Bearer `SYNC_TOKEN`) |

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export DJANGO_DEBUG=1 SYNC_TOKEN=dev     # (no DATABASE_URL: SQLite, db.sqlite3)
.venv/bin/python manage.py migrate
.venv/bin/python manage.py createsuperuser
.venv/bin/python manage.py runserver
.venv/bin/python manage.py test
```

## Hosting

Settings: environment variables (`.env.example`). The database: PostgreSQL
(`DATABASE_URL`). With Docker, the site and its own PostgreSQL:

```bash
cp .env.example .env            # secrets, POSTGRES_PASSWORD; DATABASE_URL is set by docker-compose.yml
docker compose up -d --build
docker compose exec site python manage.py createsuperuser
docker compose exec db pg_dump -U cyberchallenge cyberchallenge | gzip > site-$(date +%F).sql.gz   # a backup
```

A PostgreSQL the host provides: `docker run -d --env-file .env -p 8000:8000
cyberchallenge-site` with `DATABASE_URL` pointing at it.

Behind an https proxy (it sets `X-Forwarded-Proto`). Without Docker:
`pip install -r requirements.txt`, `manage.py migrate`, `manage.py collectstatic`,
`gunicorn cybersite.wsgi`. Erase personal data after the events, e.g. daily from
cron: `manage.py purge_personal_data --older-than 30`.

The control server (on the installation):

```bash
python control/server.py ... --website-api https://cyberchallenge.coderdojobelgium.be --website-token <SYNC_TOKEN>
```

Each QR card holds `https://<site>/register/?id=<code>`.
