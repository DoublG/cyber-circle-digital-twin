"""Erase email, postcode and place after the event (the privacy statement):
    python manage.py purge_personal_data --older-than 30      registered more than 30 days ago
    python manage.py purge_personal_data --event 14            registered at event 14
Run it from cron (e.g. daily with --older-than 30)."""
from datetime import timedelta

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from challenge.models import Registration
from challenge.privacy import purge


class Command(BaseCommand):
    help = "Erase email, postcode and place of registrations (after the event)."

    def add_arguments(self, parser):
        parser.add_argument("--older-than", type=int, metavar="DAYS")
        parser.add_argument("--event", type=int, metavar="ID")

    def handle(self, *args, older_than=None, event=None, **kw):
        if older_than is None and event is None:
            raise CommandError("give --older-than DAYS and/or --event ID")
        qs = Registration.objects.all()
        if older_than is not None:
            qs = qs.filter(created__lt=timezone.now() - timedelta(days=older_than))
        if event is not None:
            qs = qs.filter(event_id=event)
        self.stdout.write(f"{purge(qs)} registration(s) erased")
