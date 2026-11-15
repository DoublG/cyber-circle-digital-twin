from .models import Event


def site(request):
    """Every page: the current event and the earlier ones (the menu)."""
    current = Event.get_current()
    return {"current_event": current,
            "past_events": Event.objects.exclude(pk=current.pk if current else None)[:30]}
