"""A tiny PostgREST stand-in for tests: lets the REAL Python engine code (hq_engine, hq_missions) run against the replica
Postgres, so database triggers, constraints and the spend gateway are exercised through the same hq._request calls used in
production. It supports only the query shapes the engine uses (eq/neq/in/lt/lte/gt/gte/like/ilike/is/not, or=(), order, limit,
select) and POST/PATCH/rpc. It is test tooling, not production code, and it is NOT a substitute for PostgREST itself."""
import datetime
import decimal
import io
import json
import urllib.error
import urllib.parse
import uuid

import psycopg2
import psycopg2.extras

OPS = {"eq": "=", "neq": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">=", "like": "like", "ilike": "ilike"}


def _clean(v, dec=False):
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat()
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, decimal.Decimal):
        return v if dec else float(v)
    if isinstance(v, list):
        return [_clean(x, dec) for x in v]
    if isinstance(v, dict):
        return {k: _clean(x, dec) for k, x in v.items()}
    return v


def _cond(col, expr, params):
    neg = False
    if expr.startswith("not."):
        neg, expr = True, expr[4:]
    op, _, val = expr.partition(".")
    if op == "is":
        sql = f'"{col}" is null' if val == "null" else f'"{col}" is {val}'
    elif op == "in":
        items = [x.strip('"') for x in val.strip("()").split(",") if x != ""]
        sql = f'"{col}"::text = any(%s)'; params.append(items)
    elif op in OPS:
        val = urllib.parse.unquote(val)
        if op in ("like", "ilike"):
            val = val.replace("*", "%")
        sql = f'"{col}"::text {OPS[op]} %s' if op in ("like", "ilike") else f'"{col}" {OPS[op]} %s'
        params.append(val)
    else:
        raise ValueError(f"unsupported filter {col}={expr}")
    return f"not ({sql})" if neg else f"({sql})"


def _split_or(inner):
    parts, depth, cur = [], 0, ""
    for ch in inner:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += ch
    return parts + [cur]


def _group(kind, text, params):
    """text is '(a,b,or(c,d))': comma-separated conditions, each 'col.op.val' or a nested and(...)/or(...)."""
    out = []
    for c in _split_or(text.strip()[1:-1] if text.startswith("(") else text):
        head, _, rest = c.partition(".")
        if c.startswith(("or(", "and(")):
            nk, _, inner = c.partition("(")
            out.append(_group(nk, "(" + inner, params))
        else:
            out.append(_cond(head, rest, params))
    return "(" + (" or " if kind == "or" else " and ").join(out) + ")"


def parse_query(qs):
    where, params, order, limit, select = [], [], "", "", "*"
    for part in qs.split("&") if qs else []:
        k, _, v = part.partition("=")
        k, v = urllib.parse.unquote(k), v
        if k == "select":
            select = urllib.parse.unquote(v) or "*"
        elif k == "order":
            cols = []
            for o in urllib.parse.unquote(v).split(","):
                c, _, d = o.partition(".")
                cols.append(f'"{c}" {"desc" if d.startswith("desc") else "asc"}')
            order = " order by " + ", ".join(cols)
        elif k == "limit":
            limit = f" limit {int(v)}"
        elif k == "offset":
            limit += f" offset {int(v)}"
        elif k in ("on_conflict", "columns"):
            continue
        elif k in ("or", "and"):
            where.append(_group(k, urllib.parse.unquote(v), params))
        else:
            where.append(_cond(k, urllib.parse.unquote(v), params))
    return (" where " + " and ".join(where)) if where else "", params, order, limit, select


class PgAdapter:
    def __init__(self, dsn):
        self.conn = psycopg2.connect(dsn)
        self.conn.autocommit = True
        self.calls = []

    def sql(self, query, params=None, dec=False):
        with self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(query, params)
            return [_clean(dict(r), dec) for r in cur.fetchall()] if cur.description else None

    def _err(self, e):
        code = 409 if getattr(e, "pgcode", "") == "23505" else 400
        msg = (getattr(e.diag, "message_primary", None) or str(e)).strip()
        return urllib.error.HTTPError("u", code, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))

    def __call__(self, method, path, body=None, timeout=30, prefer=None, exact=False):
        self.calls.append((method, path))
        path = path.replace("/rest/v1/", "", 1)
        try:
            if path.startswith("rpc/"):
                name = path[4:]
                args = body or {}
                names = ", ".join(f'"{k}" := %s' for k in args)
                vals = [json.dumps(v) if isinstance(v, (dict, list)) else v for v in args.values()]
                rows = self.sql(f"select * from public.{name}({names})" if names else f"select * from public.{name}()", vals)
                if not rows:
                    return None
                r = rows[0]
                if len(r) == 1:
                    return list(r.values())[0]
                return rows
            table, _, qs = path.partition("?")
            where, params, order, limit, select = parse_query(qs)
            rep = prefer and "return=representation" in prefer
            if method == "GET":
                return self.sql(f'select {select} from public."{table}"{where}{order}{limit}', params, dec=exact) or []
            if method == "POST":
                rows = body if isinstance(body, list) else [body]
                out = []
                for row in rows:
                    cols = list(row)
                    vals = [json.dumps(row[c]) if isinstance(row[c], (dict, list)) else row[c] for c in cols]
                    q = f'insert into public."{table}" ({", ".join(chr(34) + c + chr(34) for c in cols)}) values ({", ".join(["%s"] * len(cols))})'
                    if prefer and "merge-duplicates" in prefer:
                        key = dict(p.split("=", 1) for p in qs.split("&") if "=" in p).get("on_conflict", "id")
                        sets = ", ".join(f'"{c}" = excluded."{c}"' for c in cols if c != key)
                        q += f' on conflict ("{key}") do update set {sets}'
                    q += " returning *"
                    out += self.sql(q, vals) or []
                return out if rep else None
            if method == "PATCH":
                cols = list(body)
                sets = ", ".join(f'"{c}" = %s' for c in cols)
                vals = [json.dumps(body[c]) if isinstance(body[c], (dict, list)) else body[c] for c in cols]
                rows = self.sql(f'update public."{table}" set {sets}{where} returning *', vals + params) or []
                return rows if rep else None
        except psycopg2.Error as e:
            raise self._err(e)
        raise ValueError(f"unsupported {method} {path}")
