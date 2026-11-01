"""Quiz questions as CSV (the gamemaster app and the web interface upload and
download them): one question per row, a header row naming the columns.
Dutch or English column names; `;` (Excel in Dutch) or `,` - detected.

    required   vraag, antwoord1, antwoord2, antwoord3, antwoord4,
               juist (1-4: the answer under square / triangle / cross / circle)
    optional   id (an existing question: updated, else added), categorie,
               min_leeftijd, max_leeftijd, tijd (s, 0 = the game's setting),
               extra_tekst, uitleg, video, video_wanneer (voor / tijdens),
               afbeelding, actief (1 / 0, ja / nee)
"""

import csv
import io

COLUMNS = ["id", "categorie", "min_leeftijd", "max_leeftijd", "vraag", "extra_tekst", "antwoord1", "antwoord2",
           "antwoord3", "antwoord4", "juist", "uitleg", "tijd", "video", "video_wanneer", "afbeelding", "actief"]
ALIASES = {                                  # column name -> the questions table's field
    "id": "id", "categorie": "category", "category": "category",
    "min_leeftijd": "min_age", "min_age": "min_age", "max_leeftijd": "max_age", "max_age": "max_age",
    "vraag": "question", "question": "question", "extra_tekst": "text", "text": "text",
    "antwoord1": "answer1", "answer1": "answer1", "antwoord2": "answer2", "answer2": "answer2",
    "antwoord3": "answer3", "answer3": "answer3", "antwoord4": "answer4", "answer4": "answer4",
    "juist": "correct", "correct": "correct", "uitleg": "explanation", "explanation": "explanation",
    "tijd": "time", "time": "time", "video": "video", "video_wanneer": "video_when", "video_when": "video_when",
    "afbeelding": "image", "image": "image", "actief": "active", "active": "active",
}
FIELDS = {v: k for k, v in ALIASES.items() if k in COLUMNS}   # field -> the Dutch column


def _int(v, default, lo=None, hi=None, what="getal"):
    """(errors in Dutch: the gamemasters read them)"""
    v = (v or "").strip()
    if v == "":
        if default is None:
            raise ValueError(f"{what} is leeg")
        return default
    try:
        n = int(float(v.replace(",", ".")))
    except ValueError:
        raise ValueError(f"{what}: '{v}' is geen getal") from None
    if (lo is not None and n < lo) or (hi is not None and n > hi):
        raise ValueError(f"{what} moet {lo}-{hi} zijn, niet {v}")
    return n


def parse(text):
    """-> (questions [(id or None, {field: value})], errors [(line, message)])."""
    text = text.lstrip("﻿")
    try:
        dialect = csv.Sniffer().sniff(text.split("\n", 1)[0], delimiters=";,\t")
    except csv.Error:
        dialect = csv.excel
    reader = csv.reader(io.StringIO(text), dialect)
    rows = list(reader)
    if not rows:
        return [], [(1, "leeg bestand")]
    head = [ALIASES.get(h.strip().lower().replace(" ", "_")) for h in rows[0]]
    missing = [c for c in ("question", "answer1", "answer2", "answer3", "answer4", "correct") if c not in head]
    if missing:
        return [], [(1, "kolom(men) ontbreken: " + ", ".join(FIELDS[m] for m in missing))]
    out, errors = [], []
    for n, row in enumerate(rows[1:], start=2):
        if not any(c.strip() for c in row):
            continue                         # (empty lines)
        raw = {f: (row[i] if i < len(row) else "").strip() for i, f in enumerate(head) if f}
        try:
            q = {
                "category": raw.get("category", ""),
                "min_age": _int(raw.get("min_age"), 0, 0, 99, "min_leeftijd"),
                "max_age": _int(raw.get("max_age"), 99, 0, 99, "max_leeftijd"),
                "question": raw["question"],
                "text": raw.get("text", ""),
                "answer1": raw["answer1"], "answer2": raw["answer2"],
                "answer3": raw["answer3"], "answer4": raw["answer4"],
                "correct": _int(raw["correct"], None, 1, 4, "juist (1 vierkant, 2 driehoek, 3 kruis, 4 cirkel)") - 1,
                "explanation": raw.get("explanation", ""),
                "video": raw.get("video", ""),
                "video_when": "during" if raw.get("video_when", "").lower() in ("tijdens", "during") else "before",
                "image": raw.get("image", ""),
                "time": _int(raw.get("time"), 0, 0, 300, "tijd"),
                "active": 0 if raw.get("active", "").lower() in ("0", "nee", "no", "false", "uit") else 1,
            }
            for f in ("question", "answer1", "answer2", "answer3", "answer4"):
                if not q[f]:
                    raise ValueError(f"{FIELDS[f]} is leeg")
            if q["min_age"] > q["max_age"]:
                raise ValueError("min_leeftijd is groter dan max_leeftijd")
            out.append((_int(raw.get("id"), 0, what="id") or None, q))
        except ValueError as e:
            errors.append((n, str(e)))
    return out, errors


def export(rows):
    """The questions table's rows as CSV (`;`, Excel in Dutch), Dutch columns."""
    f = io.StringIO()
    w = csv.writer(f, delimiter=";")
    w.writerow(COLUMNS)
    for r in rows:
        vals = []
        for c in COLUMNS:
            field = ALIASES[c]
            v = r.get(field, "")
            if field == "correct":
                v = int(v) + 1
            elif field == "video_when":
                v = "tijdens" if v == "during" else "voor"
            elif field == "time":
                v = ("%g" % float(v or 0))
            vals.append("" if v is None else v)
        w.writerow(vals)
    return "﻿" + f.getvalue()          # (the BOM: Excel reads it as UTF-8)
