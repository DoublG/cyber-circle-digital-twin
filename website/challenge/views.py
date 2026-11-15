"""The pages: home, register (the QR card's link: /register/?id=<code>),
scoreboard (the current event or an earlier one: a bar per player, how far
everyone got), every event, how it works, privacy."""
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .board import with_bars, histogram, event_days, event_numbers
from .forms import CARD_RE, CardForm, RegistrationForm
from .game_texts import DEFAULT_GAMES, JOIN_STEPS
from .models import Event, GameInfo, Registration

TALL_IMAGES = {"rhythm"}                  # (portrait: one player's screen)
GAME_IMAGES = {"quiz", "cyclone", "reaction", "simon", "rhythm", "zwarte_piet", "code"}   # static/challenge/games/<type>.jpg


def home(request):
    event = Event.get_current()
    top = with_bars(event.scores.all()[:10], event) if event else []
    return render(request, "challenge/home.html", {"event": event, "top": top,
                                                   "days": event_days(event) if event else []})


@require_http_methods(["GET", "POST"])
def register(request):
    code = (request.GET.get("id") or "").strip().rstrip("/")
    if "id=" in code:                          # (a card printed as ...?id=https://...?id=<code>)
        code = code.rsplit("id=", 1)[1]
    if not code or not CARD_RE.match(code):
        form = CardForm(request.GET or None) if code else CardForm()
        return render(request, "challenge/card.html", {"form": form, "bad": bool(code)})
    existing = Registration.objects.filter(card=code).first()
    if request.method == "POST":
        form = RegistrationForm(request.POST, instance=existing or Registration(card=code))
        if form.is_valid():
            reg = form.save(commit=False)
            reg.event = Event.get_current()
            reg.consent_at = timezone.now()
            reg.purged_at = None
            reg.save()
            return redirect(f"{request.path}done/?id={code}")
    else:
        form = RegistrationForm()               # (never prefilled: whoever has the card sees no email)
    return render(request, "challenge/register.html", {"form": form, "card": code, "existing": existing,
                                                       "again": request.GET.get("again") == "1"})


def registered(request):
    code = (request.GET.get("id") or "").strip()
    reg = get_object_or_404(Registration, card=code) if CARD_RE.match(code) else None
    if not reg:
        return redirect("register")
    return render(request, "challenge/registered.html", {"reg": reg})


def scoreboard(request, event_id=None):
    event = get_object_or_404(Event, pk=event_id) if event_id else Event.get_current()
    card = (request.GET.get("id") or "").strip()
    rows = with_bars(event.scores.all(), event) if event else []
    mine = next((r for r in rows if card and r.card == card), None)
    return render(request, "challenge/scoreboard.html", {
        "event": event, "rows": rows, "mine": mine, "live": bool(event and event.current),
        "days": event_days(event) if event else [], "numbers": event_numbers(rows),
        "histogram": histogram(rows, mine)})


def events(request):
    """Every event: its days, how many played, the best, its top 3 - and a link to its scoreboard."""
    out = []
    for e in Event.objects.prefetch_related("scores"):
        rows = with_bars(e.scores.all(), e)
        out.append({"event": e, "days": event_days(e), "numbers": event_numbers(rows), "top": rows[:3]})
    return render(request, "challenge/events.html", {"events": out})


def scoreboard_json(request, event_id=None):
    """The scoreboard as JSON (public: the same as the page - names, no cards)."""
    event = get_object_or_404(Event, pk=event_id) if event_id else Event.get_current()
    if not event:
        return JsonResponse({"event": None, "rows": []})
    return JsonResponse({
        "event": {"id": event.pk, "name": event.name, "date": event.starts_on.isoformat(), "current": event.current,
                  "days": event.days, "updated": event.scores_updated.isoformat() if event.scores_updated else None},
        "rows": [{"rank": s.rank, "name": s.name, "best": s.best, "lives": s.lives, "points": s.points,
                  "plays": s.plays} for s in event.scores.all()]})


def games(request):
    """How it works and every game, as the installation explains them (its texts, synced with
    the scoreboard; until then the game's own) - with a picture of each."""
    rows = [{"type": g.type, "title": g.title, "rules": g.rules, "off": g.off} for g in GameInfo.objects.all()] \
        or [{**g, "off": False} for g in DEFAULT_GAMES]
    for g in rows:
        g["lines"] = [l.strip() for l in g["rules"].splitlines() if l.strip()]
        g["image"] = f"challenge/games/{g['type']}.jpg" if g["type"] in GAME_IMAGES else None
        g["tall"] = g["type"] in TALL_IMAGES
    steps = [l.split(". ", 1)[-1] for l in JOIN_STEPS.splitlines() if l.strip()]
    return render(request, "challenge/games.html", {"games": rows, "steps": steps})


def how_it_works(request):
    return render(request, "challenge/how_it_works.html")


def privacy(request):
    return render(request, "challenge/privacy.html")
