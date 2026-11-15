"""A visitor's name in any script (as the control server stores it: control/db.py clean_name)."""
import unicodedata

NAME_MAX = 40
_KEEP = {"‍"}     # zero-width joiner: emoji made of several


def clean_name(name):
    """NFC, no invisible / control characters, spaces collapsed, at most NAME_MAX; "" when nothing is left."""
    s = unicodedata.normalize("NFC", str(name or ""))
    s = "".join(c if not c.isspace() else " " for c in s
                if c in _KEEP or c.isspace() or unicodedata.category(c) not in ("Cc", "Cf", "Co", "Cs", "Cn"))
    return " ".join(s.split())[:NAME_MAX].strip()
