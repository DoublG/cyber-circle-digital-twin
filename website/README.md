# Cyber Circle Challenge website

Registration with the QR card and the scoreboard, hosted on the internet
(Django 5.2). The installation's control server syncs with it: it pulls the
registrations (card, name, age) and pushes the current event's scoreboard.
Email, postcode and place stay here and are erased after the event.

| Page | |
|---|---|
| `/` | welcome, how to join, the current event's top 10 |
| `/register/?id=<card>` | the QR card's link: register (or: already registered as ...) |
| `/scoreboard/`, `/scoreboard/<id>/` | the current / an earlier event (`?id=<card>`: your place); `.json` too |
| `/how-it-works/`, `/privacy/` | |
| `/admin/` | events, registrations (CSV, winners with email, erase personal data) |
| `/api/health`, `/api/sync/...` | for the control server (Bearer `SYNC_TOKEN`) |

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export DJANGO_DEBUG=1 SYNC_TOKEN=dev
.venv/bin/python manage.py migrate
.venv/bin/python manage.py createsuperuser
.venv/bin/python manage.py runserver
.venv/bin/python manage.py test
```

## Hosting

Settings: environment variables (`.env.example`). With Docker:

```bash
docker build -t cyberchallenge-site .
docker run -d --env-file .env -p 8000:8000 -v cc-site-data:/data cyberchallenge-site
docker exec -it <container> python manage.py createsuperuser
```

Behind an https proxy (it sets `X-Forwarded-Proto`). Without Docker:
`pip install -r requirements.txt`, `manage.py migrate`, `manage.py collectstatic`,
`gunicorn cybersite.wsgi`. Erase personal data after the events, e.g. daily from
cron: `manage.py purge_personal_data --older-than 30`.

The control server (on the installation):

```bash
python control/server.py ... --website-api https://cyberchallenge.coderdojobelgium.be --website-token <SYNC_TOKEN>
```

Each QR card holds `https://<site>/register/?id=<code>`.
