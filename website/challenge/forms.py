import re

from django import forms

from .models import Registration
from .names import clean_name

CARD_RE = re.compile(r"^[A-Za-z0-9_-]{4,64}$")


class RegistrationForm(forms.ModelForm):
    consent = forms.BooleanField(
        label="Ik heb de privacyverklaring gelezen en ga akkoord. Ben je jonger dan 13? Vraag het dan eerst aan je ouder.",
        required=True, error_messages={"required": "Lees de privacyverklaring en vink dit aan."})

    class Meta:
        model = Registration
        fields = ["name", "age", "country", "email", "postcode", "place"]
        labels = {"name": "Spelersnaam", "age": "Leeftijd", "country": "Land", "email": "E-mail",
                  "postcode": "Postcode (optioneel)", "place": "Plaats (optioneel)"}
        help_texts = {"name": "Zo sta je op het scorebord - gebruik gerust een bijnaam.",
                      "email": "Alleen om je te laten weten dat je gewonnen hebt."}
        widgets = {"name": forms.TextInput(attrs={"autocomplete": "nickname", "maxlength": 40, "autofocus": True}),
                   "age": forms.NumberInput(attrs={"min": 5, "max": 99, "inputmode": "numeric"}),
                   "email": forms.EmailInput(attrs={"autocomplete": "email"}),
                   "postcode": forms.TextInput(attrs={"autocomplete": "postal-code", "inputmode": "numeric"}),
                   "place": forms.TextInput(attrs={"autocomplete": "address-level2"})}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["email"].required = True

    def clean_name(self):
        name = clean_name(self.cleaned_data.get("name"))
        if not name:
            raise forms.ValidationError("Vul een naam in.")
        return name

    def clean_age(self):
        age = self.cleaned_data["age"]
        if not 5 <= age <= 99:
            raise forms.ValidationError("Vul een leeftijd tussen 5 en 99 in.")
        return age


class CardForm(forms.Form):
    """No ?id= (the QR code not scanned): type the code on the card."""
    id = forms.CharField(label="Code op je kaart", max_length=64)

    def clean_id(self):
        code = self.cleaned_data["id"].strip()
        if not CARD_RE.match(code):
            raise forms.ValidationError("Dat is geen geldige code. Scan de QR-code op je kaart.")
        return code
