"""The website's data.

Event         a fair or festival (1-2 days): its scoreboard. Created by the
              installation's sync (control_key) or by hand in the admin.
Registration  a visitor with their QR card (card = the code on it, ?id=...).
              The control server pulls card, name and age (sync_seq: what is new);
              email, postcode and place stay here (the winners, a CoderDojo
              nearby) and are erased after the event (purge_personal_data).
Score         one row of an event's scoreboard, as the installation ranked it
              (pushed by the control server: the whole board at once).
"""
from django.db import models, transaction
from django.db.models import Max
from django.utils import timezone


class Event(models.Model):
    name = models.CharField("naam", max_length=200)
    starts_on = models.DateField("datum", default=timezone.localdate)
    current = models.BooleanField("huidig event", default=False,
                                  help_text="Het scorebord op de homepage en bij Scorebord; nieuwe registraties horen erbij.")
    control_key = models.CharField("sleutel van de installatie", max_length=64, unique=True, null=True, blank=True,
                                   help_text="Het event in de control server (gezet door de sync).")
    scores_updated = models.DateTimeField("scorebord bijgewerkt", null=True, blank=True)
    days = models.JSONField("dagen", default=list, blank=True,
                            help_text='De dagen en uren (van de installatie): [{"date": "2026-11-21", "start": "10:00", "end": "18:00"}]')

    class Meta:
        ordering = ["-starts_on", "-id"]
        verbose_name = "event"

    def __str__(self):
        return self.name

    def save(self, *args, **kwargs):
        with transaction.atomic():
            if self.current:                  # one current event
                Event.objects.exclude(pk=self.pk).filter(current=True).update(current=False)
            super().save(*args, **kwargs)

    @classmethod
    def get_current(cls):
        return cls.objects.filter(current=True).first() or cls.objects.first()


class Registration(models.Model):
    COUNTRIES = [("BE", "België"), ("NL", "Nederland"), ("FR", "Frankrijk"), ("DE", "Duitsland"),
                 ("GB", "Verenigd Koninkrijk"), ("LU", "Luxemburg"), ("XX", "Ander land")]

    card = models.CharField("kaart", max_length=64, unique=True)
    name = models.CharField("spelersnaam", max_length=40)
    age = models.PositiveSmallIntegerField("leeftijd")
    email = models.EmailField("e-mail", blank=True)
    country = models.CharField("land", max_length=2, choices=COUNTRIES, default="BE")
    postcode = models.CharField("postcode", max_length=12, blank=True)
    place = models.CharField("plaats", max_length=80, blank=True)
    event = models.ForeignKey(Event, verbose_name="event", null=True, blank=True, on_delete=models.SET_NULL)
    consent_at = models.DateTimeField("akkoord privacy", null=True, blank=True)
    created = models.DateTimeField("geregistreerd", auto_now_add=True)
    updated = models.DateTimeField("gewijzigd", auto_now=True)
    sync_seq = models.PositiveBigIntegerField("sync volgnummer", default=0, db_index=True, editable=False)
    synced_at = models.DateTimeField("opgehaald door de installatie", null=True, blank=True)
    purged_at = models.DateTimeField("persoonsgegevens gewist", null=True, blank=True)

    class Meta:
        ordering = ["-created"]
        verbose_name = "registratie"
        verbose_name_plural = "registraties"

    def __str__(self):
        return f"{self.name} ({self.card})"

    def save(self, *args, **kwargs):
        """Every change gets the next sync number: the control server asks for
        everything after the last one it has (GET /api/sync/registrations?since=)."""
        with transaction.atomic():
            last = Registration.objects.select_for_update().aggregate(m=Max("sync_seq"))["m"] or 0
            self.sync_seq = last + 1
            super().save(*args, **kwargs)


class Score(models.Model):
    event = models.ForeignKey(Event, related_name="scores", on_delete=models.CASCADE)
    rank = models.PositiveIntegerField("plaats")
    name = models.CharField("naam", max_length=40)
    card = models.CharField("kaart", max_length=64, blank=True)
    best = models.PositiveIntegerField("rondes overleefd")
    lives = models.PositiveIntegerField("levens over", default=0)
    points = models.IntegerField("punten", default=0)
    plays = models.PositiveIntegerField("keer gespeeld", default=1)

    class Meta:
        ordering = ["rank", "name"]
        verbose_name = "score"

    def __str__(self):
        return f"{self.rank}. {self.name}"


class GameInfo(models.Model):
    """A game of the installation, as it explains it (its name and rules: the operator's
    texts there) - sent with the scoreboard; "off": not played at the current event."""
    type = models.CharField("spel", max_length=32, unique=True)
    title = models.CharField("naam", max_length=80)
    rules = models.TextField("uitleg")
    position = models.PositiveSmallIntegerField("volgorde", default=0)
    off = models.BooleanField("niet op dit event", default=False)
    updated = models.DateTimeField("bijgewerkt", auto_now=True)

    class Meta:
        ordering = ["position", "title"]
        verbose_name = "spel"
        verbose_name_plural = "spellen"

    def __str__(self):
        return self.title
