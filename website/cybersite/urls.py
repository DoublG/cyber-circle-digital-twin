from django.contrib import admin
from django.urls import include, path

admin.site.site_header = "Cyber Circle Challenge"
admin.site.site_title = "Cyber Circle Challenge"

urlpatterns = [
    path("admin/", admin.site.urls),
    path("", include("challenge.urls")),
]
