"""python manage.py test (DJANGO_DEBUG=1)"""
import json
from datetime import timedelta
from io import StringIO

from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone

from .models import Event, Registration, Score

TOKEN = "test-token"
AUTH = {"HTTP_AUTHORIZATION": f"Bearer {TOKEN}"}
FORM = {"name": "  Zoë ", "age": "11", "country": "BE", "email": "zoe@example.org", "postcode": "9000",
        "place": "Gent", "consent": "on"}


@override_settings(SYNC_TOKEN=TOKEN)
class RegisterTests(TestCase):
    def test_no_card_asks_for_the_code(self):
        r = self.client.get("/register/")
        self.assertContains(r, "Code op je kaart")
        self.assertContains(self.client.get("/register/?id=no%20way!"), "geen geldige code")

    def test_register_with_the_card(self):
        Event.objects.create(name="Dag van de Wetenschap", current=True)
        r = self.client.get("/register/?id=yxaa9o1aiq4k")
        self.assertContains(r, "Spelersnaam")
        self.assertContains(r, "Privacyverklaring")
        r = self.client.post("/register/?id=yxaa9o1aiq4k", FORM)
        self.assertRedirects(r, "/register/done/?id=yxaa9o1aiq4k")
        reg = Registration.objects.get(card="yxaa9o1aiq4k")
        self.assertEqual(reg.name, "Zoë")                       # NFC, trimmed
        self.assertEqual(reg.event.name, "Dag van de Wetenschap")
        self.assertIsNotNone(reg.consent_at)
        self.assertContains(self.client.get(r.url), "Je bent geregistreerd")

    def test_the_card_printed_as_a_doubled_link(self):
        url = "/register/?id=https://cyberchallenge.coderdojobelgium.be/register?id=yxaa9o1aiq4k"
        self.assertContains(self.client.get(url), "yxaa9o1aiq4k")

    def test_consent_name_and_age_needed(self):
        r = self.client.post("/register/?id=abcd1234", {**FORM, "consent": "", "name": "​", "age": "3"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "privacyverklaring en vink")
        self.assertContains(r, "Vul een naam in")
        self.assertContains(r, "tussen 5 en 99")
        self.assertFalse(Registration.objects.exists())

    def test_registered_card_shows_the_name_not_the_email(self):
        Registration.objects.create(card="abcd1234", name="Lot", age=9, email="secret@example.org")
        r = self.client.get("/register/?id=abcd1234")
        self.assertContains(r, "al geregistreerd als")
        self.assertNotContains(r, "secret@example.org")
        r = self.client.get("/register/?id=abcd1234&again=1")
        self.assertNotContains(r, "secret@example.org")       # the form is never prefilled
        self.client.post("/register/?id=abcd1234", {**FORM, "name": "Lotte"})
        self.assertEqual(Registration.objects.get(card="abcd1234").name, "Lotte")
        self.assertEqual(Registration.objects.count(), 1)


@override_settings(SYNC_TOKEN=TOKEN)
class SyncTests(TestCase):
    def test_health_without_token(self):
        self.assertEqual(self.client.get("/api/health").json()["ok"], True)

    def test_token_needed(self):
        self.assertEqual(self.client.get("/api/sync/registrations").status_code, 401)
        self.assertEqual(self.client.get("/api/sync/registrations", HTTP_AUTHORIZATION="Bearer nope").status_code, 401)
        self.assertEqual(self.client.put("/api/sync/scoreboard", "{}", content_type="application/json").status_code, 401)

    @override_settings(SYNC_TOKEN="")
    def test_no_token_configured_nobody_gets_in(self):
        self.assertEqual(self.client.get("/api/sync/registrations", HTTP_AUTHORIZATION="Bearer ").status_code, 401)

    def test_registrations_after_a_number(self):
        a = Registration.objects.create(card="card0001", name="Anna", age=12, email="a@example.org", postcode="1000")
        Registration.objects.create(card="card0002", name="Bram", age=7, email="b@example.org")
        j = self.client.get("/api/sync/registrations?since=0", **AUTH).json()
        self.assertEqual([r["card"] for r in j["registrations"]], ["card0001", "card0002"])
        self.assertEqual(set(j["registrations"][0]), {"card", "name", "age"})   # no email / postcode
        self.assertEqual(self.client.get(f"/api/sync/registrations?since={j['next']}", **AUTH).json()["registrations"], [])
        a.name = "Anna B"
        a.save()                                                   # changed: comes again
        j2 = self.client.get(f"/api/sync/registrations?since={j['next']}", **AUTH).json()
        self.assertEqual([r["name"] for r in j2["registrations"]], ["Anna B"])
        self.assertIsNotNone(Registration.objects.get(card="card0002").synced_at)

    def test_scoreboard_replaced_as_a_whole(self):
        body = {"event": {"key": "7-2026-11-15", "name": "Dag van de Wetenschap", "date": "2026-11-15", "current": True},
                "rows": [{"rank": 1, "name": "Anna", "card": "card0001", "best": 12, "lives": 2, "points": 300, "plays": 2},
                         {"rank": 2, "name": "Bram", "card": "", "best": 9, "lives": 0, "points": 150, "plays": 1}]}
        r = self.client.put("/api/sync/scoreboard", json.dumps(body), content_type="application/json", **AUTH)
        self.assertEqual(r.json()["rows"], 2)
        ev = Event.objects.get(control_key="7-2026-11-15")
        self.assertTrue(ev.current)
        body["rows"] = body["rows"][:1]
        self.client.put("/api/sync/scoreboard", json.dumps(body), content_type="application/json", **AUTH)
        self.assertEqual(Event.objects.count(), 1)
        self.assertEqual(list(Score.objects.values_list("name", flat=True)), ["Anna"])
        page = self.client.get("/scoreboard/?id=card0001")
        self.assertContains(page, "Jij staat op plaats <b>1</b>")
        self.assertContains(page, "LIVE")
        j = self.client.get("/scoreboard.json").json()
        self.assertEqual(j["rows"][0]["name"], "Anna")
        self.assertNotIn("card", j["rows"][0])                    # (public: no card codes)
        self.assertEqual(self.client.put("/api/sync/scoreboard", "nope", content_type="application/json", **AUTH).status_code, 400)

    def test_the_event_days_from_the_installation(self):
        days = [{"date": "2026-11-22", "start": "10:00", "end": "17:00"}, {"date": "2026-11-21", "start": "10:00", "end": "18:00"},
                {"date": "nope", "start": "x", "end": "y"}]
        body = {"event": {"key": "8-x", "name": "Maker Faire", "date": "2026-11-21", "current": True, "days": days}, "rows": []}
        self.client.put("/api/sync/scoreboard", json.dumps(body), content_type="application/json", **AUTH)
        ev = Event.objects.get(control_key="8-x")
        self.assertEqual([d["date"] for d in ev.days], ["2026-11-21", "2026-11-22"])      # sorted, the bad one out
        page = self.client.get("/scoreboard/")
        self.assertContains(page, "za 21/11 <b>10:00–18:00</b>")
        self.assertContains(page, "zo 22/11 <b>10:00–17:00</b>")
        self.assertEqual(self.client.get("/scoreboard.json").json()["event"]["days"], ev.days)

    def test_one_current_event(self):
        a = Event.objects.create(name="A", current=True)
        Event.objects.create(name="B", current=True)
        a.refresh_from_db()
        self.assertFalse(a.current)


class PagesTests(TestCase):
    def test_pages_and_past_events(self):
        old = Event.objects.create(name="Nerdland Festival", starts_on=timezone.localdate() - timedelta(days=200))
        now = Event.objects.create(name="Dag van de Wetenschap", current=True)
        Score.objects.create(event=now, rank=1, name="Anna", best=5)
        home = self.client.get("/")
        self.assertContains(home, "Welkom bij de CoderDojo Cyber Circle Challenge")
        self.assertContains(home, "Anna")
        self.assertContains(home, f"/scoreboard/{old.pk}/")           # the menu: earlier events
        self.assertContains(self.client.get(f"/scoreboard/{old.pk}/"), "Nog niemand")
        for url in ("/how-it-works/", "/privacy/", "/scoreboard/"):
            self.assertEqual(self.client.get(url).status_code, 200)

    def test_the_bars_and_how_far_everyone_got(self):
        ev = Event.objects.create(name="Dag van de Wetenschap", current=True)
        for i, (name, best) in enumerate([("Anna", 12), ("Bram", 6), ("Cas", 6), ("Dina", 0)]):
            Score.objects.create(event=ev, rank=i + 1, name=name, card=f"card000{i}", best=best)
        page = self.client.get("/scoreboard/?id=card0001")
        self.assertContains(page, 'style="width: 100%"')                 # Anna: the best
        self.assertContains(page, 'style="width: 50%"', count=2)         # Bram, Cas: half of it
        self.assertContains(page, 'style="width: 0%"')                   # Dina: nothing yet
        self.assertContains(page, "Hoe ver kwam iedereen?")
        self.assertContains(page, "6 rondes: 2 spelers")                 # the chart
        self.assertContains(page, '<div class="col me" title="6 rondes: 2 spelers">')   # Bram's column
        self.assertContains(page, "<b>4</b> spelers")
        from .board import histogram, with_bars
        rows = [type("R", (), {"best": b})() for b in range(0, 60)]
        h = histogram(rows)
        self.assertLessEqual(len(h), 24)
        self.assertEqual((h[0]["label"], h[0]["range"], h[0]["size"]), ("0", "0–2", 3))   # (far: in groups)
        self.assertEqual(sum(c["count"] for c in h), 60)
        top = with_bars(ev.scores.all()[1:2], ev)                          # (a part: against the event's best)
        self.assertEqual(top[0].bar, 50)

    def test_events_page(self):
        old = Event.objects.create(name="Nerdland Festival", starts_on=timezone.localdate() - timedelta(days=200),
                                   days=[{"date": "2026-05-30", "start": "10:00", "end": "22:00"}])
        now = Event.objects.create(name="Dag van de Wetenschap", current=True)
        Score.objects.create(event=old, rank=1, name="Anna", best=9, plays=3)
        page = self.client.get("/events/")
        self.assertContains(page, "Nerdland Festival")
        self.assertContains(page, "za 30/5 <b>10:00–22:00</b>")
        self.assertContains(page, "<b>1</b> spelers · <b>3</b> keer gespeeld · beste: <b>9</b> rondes")
        self.assertContains(page, f"/scoreboard/{now.pk}/")
        self.assertContains(page, "● NU")

    def test_games_page_the_games_own_texts_until_the_installation_sends_its_own(self):
        page = self.client.get("/games/")
        self.assertContains(page, "Code kraken")                       # (the game's own texts, built in)
        self.assertContains(page, "Kraak de geheime code")
        self.assertContains(page, "challenge/games/cyclone.jpg")
        self.assertContains(page, "Haal een QR-codekaart.")
        self.assertNotContains(page, "niet op dit event")

    @override_settings(SYNC_TOKEN=TOKEN)
    def test_games_from_the_installation(self):
        body = {"event": {"key": "9-x", "name": "E", "current": True}, "rows": [],
                "games": [{"type": "quiz", "title": "De Grote Quiz", "rules": "Regel 1\r\nRegel 2"},
                          {"type": "code", "title": "Code kraken", "rules": "Kraak het.", "off": True},
                          {"type": "../evil", "title": "x", "rules": "y"}]}
        self.client.put("/api/sync/scoreboard", json.dumps(body), content_type="application/json", **AUTH)
        page = self.client.get("/games/")
        self.assertContains(page, "De Grote Quiz")
        self.assertContains(page, "<p>Regel 1</p><p>Regel 2</p>")
        self.assertContains(page, "niet op dit event", count=1)
        self.assertNotContains(page, "Cyclone")                        # (the installation's list, as a whole)
        self.assertNotContains(page, "evil")

    def test_purge_after_the_event(self):
        r = Registration.objects.create(card="card0001", name="Anna", age=12, email="a@example.org", postcode="1000", place="X")
        Registration.objects.filter(pk=r.pk).update(created=timezone.now() - timedelta(days=40))
        Registration.objects.create(card="card0002", name="Bram", age=7, email="b@example.org")
        out = StringIO()
        call_command("purge_personal_data", "--older-than", "30", stdout=out)
        self.assertIn("1 registration", out.getvalue())
        r.refresh_from_db()
        self.assertEqual((r.email, r.postcode, r.place, r.name), ("", "", "", "Anna"))
        self.assertEqual(Registration.objects.get(card="card0002").email, "b@example.org")
