#!/usr/bin/env python3
"""Copies the control server's database to another one: an installation's old
MySQL / MariaDB database (or a SQLite file) into PostgreSQL. Every table, every
row, the ids as they are (the players' QR cards, the events and their rankings
stay); PostgreSQL's id counters are set past them. The source is only read.

Stop the control server first (nothing may write meanwhile), then, with the
control server's virtualenv (it has SQLAlchemy, PyMySQL and psycopg):

  control/.venv/bin/python tools/ops/migrate_db.py \\
      --from "mysql+pymysql://cybercircle:OLDPW@localhost/cybercircle?charset=utf8mb4" \\
      --to   "postgresql+psycopg://cybercircle:NEWPW@localhost/cybercircle"

The target must be empty (or hold only what a control server writes on its very
first start: --replace empties it first). At the end the rows of every table are
counted on both sides; a difference is an error (exit 1). --if-empty: a target
with data is left alone (exit 0) - install_server.sh, run again."""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "control"))
import db as dbm                                    # noqa: E402  (the tables, as the control server makes them)
from sqlalchemy import MetaData, create_engine, func, inspect, select, text   # noqa: E402

BATCH = 1000


def _hide(url):
    """The URL without its password (for the output)."""
    u = create_engine(url).url if "://" in url else None
    return u.render_as_string(hide_password=True) if u else url


def migrate(src_url, dst_url, replace=False, out=print, if_empty=False):
    src = create_engine(dbm.engine_url(src_url))
    dst = create_engine(dbm.engine_url(dst_url))
    have = set(inspect(src).get_table_names())
    missing = [t.name for t in dbm.meta.sorted_tables if t.name not in have]
    if "players" not in have or "settings" not in have:
        raise SystemExit(f"{_hide(src_url)}: not a Cyber Circle database (no players / settings table)")
    old = MetaData()
    old.reflect(src, only=[t.name for t in dbm.meta.sorted_tables if t.name in have])

    if replace:
        dbm.meta.drop_all(dst)
    dbm.meta.create_all(dst)
    with dst.connect() as con:
        full = {t.name: n for t in dbm.meta.sorted_tables
                if (n := con.execute(select(func.count()).select_from(t)).scalar())}
    if full and if_empty:                             # (install_server.sh run again: moved already)
        out(f"  {_hide(dst_url)} has data already: nothing copied")
        return None
    if full:
        raise SystemExit(f"{_hide(dst_url)} is not empty ({', '.join(f'{k}: {v}' for k, v in full.items())}): "
                         "--replace empties it first")

    counts = {}
    with src.connect() as rc, dst.begin() as wc:     # (one transaction: all of it or nothing)
        for table in dbm.meta.sorted_tables:          # (parents first: events before games before results)
            if table.name not in have:
                continue
            o = old.tables[table.name]
            cols = [c.name for c in table.columns if c.name in o.c]
            n, batch = 0, []
            for row in rc.execute(select(*[o.c[c] for c in cols])).mappings():
                batch.append(dict(row))
                if len(batch) == BATCH:
                    wc.execute(table.insert(), batch)
                    n, batch = n + len(batch), []
            if batch:
                wc.execute(table.insert(), batch)
                n += len(batch)
            counts[table.name] = n
            gone = [c.name for c in table.columns if c.name not in o.c]
            out(f"  {table.name:14} {n:7} rows" + (f"  (new columns, their defaults: {', '.join(gone)})" if gone else ""))
        if dst.dialect.name == "postgresql":          # the id counters: past the copied ids
            for table in dbm.meta.sorted_tables:
                pk = list(table.primary_key.columns)
                if len(pk) == 1 and pk[0].autoincrement is True:
                    wc.execute(text(f"SELECT setval(pg_get_serial_sequence('{table.name}', '{pk[0].name}'), "
                                    f"COALESCE(MAX({pk[0].name}), 1), MAX({pk[0].name}) IS NOT NULL) "
                                    f"FROM {table.name}"))

    with dst.connect() as con:                       # the check: as many rows on both sides
        bad = {t: (n, got) for t, n in counts.items()
               if (got := con.execute(select(func.count()).select_from(dbm.meta.tables[t])).scalar()) != n}
    src.dispose()
    dst.dispose()
    if missing:
        out(f"  (not in the source, made empty: {', '.join(missing)})")
    if bad:
        raise SystemExit("row counts differ: " + ", ".join(f"{t} {a} -> {b}" for t, (a, b) in bad.items()))
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", required=True, help="the old database: a SQLAlchemy URL or a SQLite file")
    ap.add_argument("--to", dest="dst", required=True, help="the new one, e.g. postgresql+psycopg://user:pw@host/db")
    ap.add_argument("--replace", action="store_true", help="empty the target first (its Cyber Circle tables)")
    ap.add_argument("--if-empty", action="store_true", help="a target with data: leave it, copy nothing (exit 0)")
    a = ap.parse_args()
    print(f"{_hide(a.src)} -> {_hide(a.dst)}")
    counts = migrate(a.src, a.dst, a.replace, if_empty=a.if_empty)
    if counts is None:
        return
    print(f"done: {sum(counts.values())} rows in {len(counts)} tables, the counts match")


if __name__ == "__main__":
    main()
