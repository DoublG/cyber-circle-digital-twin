"""The pages: home, register (the QR card's link: /register/?id=<code>),
scoreboard (the current event or an earlier one), how it works, privacy."""
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .forms import CARD_RE, CardForm, RegistrationForm
from .models import Event, Registration


def home(request):
    event = Event.get_current()
    top = event.scores.all()[:10] if event else []
    return render(request, "challenge/home.html", {"event": event, "top": top})


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
    rows = list(event.scores.all()) if event else []
    mine = next((r for r in rows if card and r.card == card), None)
    return render(request, "challenge/scoreboard.html", {"event": event, "rows": rows, "mine": mine,
                                                         "live": bool(event and event.current)})


def scoreboard_json(request, event_id=None):
    """The scoreboard as JSON (public: the same as the page - names, no cards)."""
    event = get_object_or_404(Event, pk=event_id) if event_id else Event.get_current()
    if not event:
        return JsonResponse({"event": None, "rows": []})
    return JsonResponse({
        "event": {"id": event.pk, "name": event.name, "date": event.starts_on.isoformat(), "current": event.current,
                  "updated": event.scores_updated.isoformat() if event.scores_updated else None},
        "rows": [{"rank": s.rank, "name": s.name, "best": s.best, "lives": s.lives, "points": s.points,
                  "plays": s.plays} for s in event.scores.all()]})


def how_it_works(request):
    return render(request, "challenge/how_it_works.html")


def privacy(request):
    return render(request, "challenge/privacy.html")
