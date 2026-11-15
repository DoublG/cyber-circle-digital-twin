from django.urls import path

from . import api, views

urlpatterns = [
    path("", views.home, name="home"),
    path("register/", views.register, name="register"),
    path("register/done/", views.registered, name="registered"),
    path("scoreboard/", views.scoreboard, name="scoreboard"),
    path("scoreboard/<int:event_id>/", views.scoreboard, name="scoreboard_event"),
    path("scoreboard.json", views.scoreboard_json, name="scoreboard_json"),
    path("scoreboard/<int:event_id>.json", views.scoreboard_json, name="scoreboard_event_json"),
    path("how-it-works/", views.how_it_works, name="how_it_works"),
    path("privacy/", views.privacy, name="privacy"),
    path("api/health", api.health, name="api_health"),
    path("api/sync/registrations", api.registrations, name="api_registrations"),
    path("api/sync/scoreboard", api.scoreboard, name="api_scoreboard"),
]
