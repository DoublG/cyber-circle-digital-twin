"""The sync API for the installation's control server (it calls out: the
installation is on its own network, nothing calls in). Authorization:
Bearer <SYNC_TOKEN>.

GET  /api/health                       up? (no token; the control server checks it)
GET  /api/sync/registrations?since=N   the registrations changed after sync number N:
                                       {"registrations": [{card, name, age}], "next": N', "more", "last"}
                                       (last < N: this database was started again - ask from 0)
                                       (only what the game needs: no email, postcode, place)
PUT  /api/sync/scoreboard              an event's whole scoreboard as the installation ranked it:
                                       {"event": {"key", "name", "date", "current"},
                                        "rows": [{rank, name, card, best, lives, points, plays}]}
"""
import datetime
import hmac
import json

from django.conf import settings
from django.db import transaction
from django.db.models import Max
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_http_methods

from .models import Event, Registration, Score
from .names import clean_name

BATCH = 500


def _authorized(request):
    token = settings.SYNC_TOKEN
    given = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    return bool(token) and hmac.compare_digest(given.encode(), token.encode())


def _deny():
    return JsonResponse({"error": "unauthorized"}, status=401)


@require_GET
def health(request):
    return JsonResponse({"ok": True, "time": timezone.now().isoformat()})


@require_GET
def registrations(request):
    if not _authorized(request):
        return _deny()
    try:
        since = int(request.GET.get("since", "0"))
    except ValueError:
        return JsonResponse({"error": "since: a number"}, status=400)
    rows = list(Registration.objects.filter(sync_seq__gt=since).order_by("sync_seq")[:BATCH])
    if rows:
        Registration.objects.filter(pk__in=[r.pk for r in rows]).update(synced_at=timezone.now())
    last = Registration.objects.aggregate(m=Max("sync_seq"))["m"] or 0
    return JsonResponse({"registrations": [{"card": r.card, "name": r.name, "age": r.age} for r in rows],
                         "next": rows[-1].sync_seq if rows else since, "more": len(rows) == BATCH,
                         "last": last})


def _int(v, lo=0):
    try:
        return max(lo, int(v))
    except (TypeError, ValueError):
        return lo


@csrf_exempt
@require_http_methods(["PUT", "POST"])
def scoreboard(request):
    if not _authorized(request):
        return _deny()
    try:
        body = json.loads(request.body or b"{}")
        ev, rows = body["event"], body["rows"]
        key = str(ev["key"])[:64]
        assert key and isinstance(rows, list)
    except (ValueError, KeyError, TypeError, AssertionError):
        return JsonResponse({"error": 'expected {"event": {"key", "name", ...}, "rows": [...]}'}, status=400)
    with transaction.atomic():
        event = Event.objects.filter(control_key=key).first() or Event(control_key=key)
        event.name = clean_name(ev.get("name")) or event.name or "Event"
        try:
            event.starts_on = datetime.date.fromisoformat(str(ev.get("date"))[:10])
        except ValueError:
            pass
        if "current" in ev:
            event.current = bool(ev["current"])
        event.scores_updated = timezone.now()
        event.save()
        event.scores.all().delete()
        Score.objects.bulk_create([
            Score(event=event, rank=_int(r.get("rank"), 1), name=clean_name(r.get("name")) or "?",
                  card=str(r.get("card") or "")[:64], best=_int(r.get("best")), lives=_int(r.get("lives")),
                  points=_int(r.get("points"), -10**9), plays=_int(r.get("plays"), 1))
            for r in rows[:5000] if isinstance(r, dict)])
    return JsonResponse({"ok": True, "event": event.pk, "rows": event.scores.count()})
