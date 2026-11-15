from django.utils import timezone


def purge(registrations):
    """Erase what the privacy statement promises to erase after the event: email,
    postcode and place. The name (a nickname) and age stay for the scoreboard and
    the card. Returns how many were erased."""
    return registrations.filter(purged_at__isnull=True).update(email="", postcode="", place="",
                                                               purged_at=timezone.now())
