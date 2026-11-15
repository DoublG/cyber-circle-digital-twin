import csv

from django.contrib import admin, messages
from django.http import HttpResponse

from .models import Event, Registration, Score
from .privacy import purge


class ScoreInline(admin.TabularInline):
    model = Score
    extra = 0
    fields = ["rank", "name", "card", "best", "lives", "points", "plays"]
    readonly_fields = fields
    can_delete = False
    max_num = 0


@admin.register(Event)
class EventAdmin(admin.ModelAdmin):
    list_display = ["name", "starts_on", "current", "scores_updated", "players"]
    list_editable = ["current"]
    inlines = [ScoreInline]
    actions = ["winners_csv", "purge_event"]

    @admin.display(description="spelers op het scorebord")
    def players(self, obj):
        return obj.scores.count()

    @admin.action(description="Winnaars met e-mail (CSV, top 10)")
    def winners_csv(self, request, queryset):
        resp = HttpResponse(content_type="text/csv; charset=utf-8")
        resp["Content-Disposition"] = 'attachment; filename="winnaars.csv"'
        resp.write("﻿")                        # (Excel: UTF-8)
        w = csv.writer(resp, delimiter=";")
        w.writerow(["event", "plaats", "naam", "rondes", "levens", "punten", "kaart", "e-mail", "leeftijd"])
        for ev in queryset:
            for s in ev.scores.filter(rank__lte=10):
                reg = Registration.objects.filter(card=s.card).first() if s.card else None
                w.writerow([ev.name, s.rank, s.name, s.best, s.lives, s.points, s.card,
                            reg.email if reg else "", reg.age if reg else ""])
        return resp

    @admin.action(description="Persoonsgegevens wissen van wie zich bij dit event registreerde")
    def purge_event(self, request, queryset):
        n = purge(Registration.objects.filter(event__in=queryset))
        self.message_user(request, f"{n} registratie(s) gewist (e-mail, postcode, plaats).", messages.SUCCESS)


@admin.register(Registration)
class RegistrationAdmin(admin.ModelAdmin):
    list_display = ["name", "card", "age", "country", "email", "event", "created", "synced_at", "purged_at"]
    list_filter = ["event", "country", ("synced_at", admin.EmptyFieldListFilter), ("purged_at", admin.EmptyFieldListFilter)]
    search_fields = ["name", "card", "email"]
    readonly_fields = ["created", "updated", "sync_seq", "synced_at", "consent_at", "purged_at"]
    actions = ["purge_selected", "export_csv"]

    @admin.action(description="Persoonsgegevens wissen (e-mail, postcode, plaats)")
    def purge_selected(self, request, queryset):
        n = purge(queryset)
        self.message_user(request, f"{n} registratie(s) gewist.", messages.SUCCESS)

    @admin.action(description="Exporteren (CSV)")
    def export_csv(self, request, queryset):
        resp = HttpResponse(content_type="text/csv; charset=utf-8")
        resp["Content-Disposition"] = 'attachment; filename="registraties.csv"'
        resp.write("﻿")
        w = csv.writer(resp, delimiter=";")
        w.writerow(["kaart", "naam", "leeftijd", "land", "postcode", "plaats", "e-mail", "event", "geregistreerd"])
        for r in queryset:
            w.writerow([r.card, r.name, r.age, r.country, r.postcode, r.place, r.email, r.event or "",
                        r.created.strftime("%Y-%m-%d %H:%M")])
        return resp
