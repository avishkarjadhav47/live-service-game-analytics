"""Small helpers shared by the notebooks.

connect()       opens the local MySQL database built by sql/setup.sql.
                The password is read from the MYSQL_PASSWORD environment
                variable, or asked for interactively if it is not set.
run_query(sql)  returns one query as a DataFrame.
run_sql_file()  runs every statement in a sql/ file and returns the result
                sets in order, so the notebooks use exactly the queries in
                the SQL files rather than copies of them.
"""

import os
import re
from decimal import Decimal
from getpass import getpass
from pathlib import Path

import mysql.connector
import pandas as pd

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"
_conn = None


def connect():
    global _conn
    if _conn is None or not _conn.is_connected():
        password = os.environ.get("MYSQL_PASSWORD") or getpass("MySQL password: ")
        _conn = mysql.connector.connect(
            host=os.environ.get("MYSQL_HOST", "localhost"),
            user=os.environ.get("MYSQL_USER", "root"),
            password=password,
            database="ea_analyst_takehome",
        )
    return _conn


def _to_numeric(df):
    for col in df.columns:
        if df[col].map(lambda v: isinstance(v, Decimal)).any():
            df[col] = pd.to_numeric(df[col], errors="coerce").astype(float)
    return df


def run_query(sql):
    cur = connect().cursor()
    cur.execute(sql)
    cols = [c[0] for c in cur.description]
    df = pd.DataFrame(cur.fetchall(), columns=cols)
    cur.close()
    return _to_numeric(df)


def _statements(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)          # block comments
    text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))
    parts = [p.strip() for p in text.split(";")]
    return [p for p in parts if p and not p.upper().startswith("USE ")]


def run_sql_file(name):
    """Run sql/<name> and return a list of DataFrames, one per SELECT."""
    results = []
    for stmt in _statements((SQL_DIR / name).read_text(encoding="utf-8")):
        results.append(run_query(stmt))
    return results


def close():
    global _conn
    if _conn is not None:
        _conn.close()
        _conn = None
