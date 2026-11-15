"""The games as the installation explains them (its texts: the operator can change
them there). The website shows these until the installation has sent its own
(with the scoreboard: GameInfo). Made from the game's defaults (Texts.defaults)."""

DEFAULT_GAMES = [
    {"type": 'quiz', "title": 'Quiz',
     "rules": 'Druk op je tegel op het icoon van je antwoord (zelfde vorm, kleur en plek).\nJe mag je antwoord veranderen tot de tijd om is: je laatste keuze telt.\nJuist: je blijft in het spel. Fout of te laat: je verliest een leven.\n10 juiste antwoorden op rij = +1 leven!'},
    {"type": 'cyclone', "title": 'Cyclone',
     "rules": 'Een groen lampje draait rondjes op jouw tegel.\nDruk op een knop op het moment dat het op het RODE lampje staat.\nGeel mag ook, maar na elke treffer worden de gele stroken kleiner!\nErnaast? Dan begin je opnieuw bij het eerste niveau.\nNa de ronde: hoogste niveau +1 leven, laagste niveau -1 leven.'},
    {"type": 'reaction', "title": 'Reactie',
     "rules": 'Er licht een kleur op je tegel op: druk zo snel mogelijk op dat icoon.\nROOD is een val: niet drukken! Wacht of druk een ander icoon.\nElke treffer gaat het sneller, een fout en je begint weer traag.\nNa de ronde: langste reeks treffers +1 leven, kortste -1 leven.'},
    {"type": 'simon', "title": 'Simon zegt',
     "rules": 'Je tegel toont een reeks iconen: onthoud ze en druk ze in dezelfde volgorde.\nElke keer komt er een icoon bij. Fout of te traag? Dan begin je opnieuw bij het begin.\nNa de ronde: langste reeks +1 leven, kortste -1 leven.'},
    {"type": 'rhythm', "title": 'Ritme',
     "rules": 'Iconen vallen naar beneden op je scherm, elk in de kleur van zijn knop.\nDruk dat icoon op je tegel als het onderaan aankomt:\nin de gele band +1, precies op de lijn +3 punten. Zomaar drukken: -1.\nEerst tikken. Dan ook vasthouden: een icoon met een balk erachter?\nBlijf erop staan en laat los als het einde van de balk op de lijn komt!\nDaarna sneller en twee tegelijk.\nNa de ronde: meeste punten +1 leven, minste punten -1 leven.'},
    {"type": 'zwarte_piet', "title": 'Zwarte Piet',
     "rules": 'Een lampje draait rond op een tegel. Heb jij het? Schop het snel weg!\nLinks (vierkant of kruis) of rechts (driehoek of cirkel) naar je buur.\nNiemand weet wanneer de tijd om is: wie het lampje dan heeft verliest een punt.\nNa de ronde: meeste punten +1 leven, minste punten -1 leven.'},
    {"type": 'code', "title": 'Code kraken',
     "rules": 'Kraak de geheime code: een rij iconen. Druk een rij iconen op je tegel.\nNa elke poging krijgt elk icoon een kleur, op je scherm en je tegel:\ngroen = juiste plek, geel = zit erin maar op een andere plek, grijs = zit er niet in.\nGekraakt: +6 punten, +1 voor elke poging minder dan 8. Dan een moeilijkere code!\nNa de ronde: meeste punten +1 leven, minste punten -1 leven.'},
]

JOIN_STEPS = '1. Haal een QR-codekaart.\n2. Registreer je met je gsm.\n3. Ga naar een gamemaster: die laat je toe tot het spel.\n4. Zoek de tegel in jouw kleur en druk op de 4 iconen.\n5. Blijf zo lang mogelijk in het spel!'

