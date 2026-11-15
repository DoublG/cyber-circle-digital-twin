#!/usr/bin/env python3
"""tools/ops/migrate_db.py: an old database copied over - every row, the same
ranking, names in any script, the large checkpoint; new ids after the copied
ones; a target with data refused (--if-empty: left alone).
  python control/test_migrate.py                       (SQLite -> SQLite)
  CC_TEST_DB=postgresql+psycopg://user:pw@host/db python control/test_migrate.py   (SQLite -> PostgreSQL)
  CC_TEST_SRC_DB=mysql+pymysql://... (the source: MySQL / MariaDB instead of a SQLite file; emptied first)"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "ops"))
import db as dbm                                    # noqa: E402
import demo_history                                 # noqa: E402
import migrate_db                                   # noqa: E402
from sqlalchemy import create_engine                # noqa: E402

fails = 0


def check(ok, what):
    global fails
    print(("    [ok] " if ok else "    [FAIL] ") + what)
    fails += 0 if ok else 1


def empty(url):
    if "://" in url:
        e = create_engine(url)
        dbm.meta.drop_all(e)
        e.dispose()


tmp = tempfile.mkdtemp()
SRC = os.environ.get("CC_TEST_SRC_DB") or os.path.join(tmp, "old.db")
DST = os.environ.get("CC_TEST_DB") or os.path.join(tmp, "new.db")
empty(SRC)
empty(DST)
try:
    print("--- the old database: an event with 120 players, a gamemaster, a placed tile, the checkpoint")
    demo_history.seed(SRC, players=120, days=2)
    old = dbm.Database(SRC)
    old.add_player("Lot 👩‍💻", age=11, card="CC-EMOJI")
    old.upsert_card("CC-ARAB", "محمد", 12, "ouder@example.org")
    old.save_gamemaster("Erik", "#ff0000")
    old.set_tile(3, "aa:bb:cc", enabled=False)
    if old.engine.dialect.name == "mysql":          # (as the installations have it: MEDIUMTEXT, the checkpoint)
        with old.engine.begin() as con:
            con.execute(dbm.text("ALTER TABLE settings MODIFY value MEDIUMTEXT NOT NULL"))
    old.set_setting("checkpoint", "x" * 2_000_000)
    old.engine.dispose()

    print("--- copied over")
    counts = migrate_db.migrate(SRC, DST, out=lambda *_: None)
    check(counts["players"] == 122 and counts["results"] > 0 and counts["round_scores"] > 0,
          f"every table ({sum(counts.values())} rows; players {counts['players']}, results {counts['results']})")
    a, b = dbm.Database(SRC), dbm.Database(DST)
    check(a.leaderboard() == b.leaderboard() and len(b.leaderboard()) >= 100, "the same ranking")
    check(a.events() == b.events(), "the same events")
    check(b.player_by_card("CC-EMOJI")["name"] == "Lot 👩‍💻" and b.player_by_card("CC-ARAB")["name"] == "محمد",
          "names in any script")
    check(len(b.setting("checkpoint")) == 2_000_000 and b.setting("db_id") == a.setting("db_id"),
          "the settings (the checkpoint, the database's own id)")
    check([t for t in b.tiles() if t["device"]] == [{"number": 3, "device": "aa:bb:cc", "enabled": 0, "press": 100}],
          "the tiles (and a column added since: its default)")
    check([g["name"] for g in b.gamemasters()] == ["Erik"], "the gamemasters")
    pid, gid = b.add_player("Nieuw"), b.start_game()
    check(pid == 123 and gid > max(g["id"] for g in a.export_event(a.current_event_id())["games"]),
          f"new ids after the copied ones (player {pid}, game {gid})")
    a.engine.dispose()
    b.engine.dispose()

    print("--- again: the target has data")
    try:
        migrate_db.migrate(SRC, DST, out=lambda *_: None)
        check(False, "refused")
    except SystemExit as e:
        check("not empty" in str(e), "refused (--replace empties it first)")
    check(migrate_db.migrate(SRC, DST, if_empty=True, out=lambda *_: None) is None, "--if-empty: left alone")
    counts = migrate_db.migrate(SRC, DST, replace=True, out=lambda *_: None)
    check(counts["players"] == 122, "--replace: copied again")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "ops", "migrate_db.py"), "--from", SRC, "--to", DST,
                        "--if-empty"], capture_output=True, text=True)
    check(r.returncode == 0 and "nothing copied" in r.stdout, "the command line (--if-empty)")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f"\nDONE: {fails} failure(s)")
sys.exit(1 if fails else 0)
