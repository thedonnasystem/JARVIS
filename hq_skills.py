"""
Restricted loader for Jarvis's skills (jarvis_skills/*.py). PROTECTED file. jarvis_skills/ is NOT in the auto-ship zone any more (RVJC2 B4, Nov 17 2026):
every skill change needs the owner's approval, because the in-process checks below were escaped in review (enum.sys.modules, json.dumps.__globals__).

A skill is plain Python with `def run(payload: dict) -> dict`. It is NOT imported as a module: the loader parses it, refuses it unless every import is on
ALLOWED_IMPORTS (pure standard library, no I/O, no os / sys / importlib / socket / subprocess, no hq_* or any protected module), and refuses names and
attributes that reach the interpreter's internals (dunder names, eval / exec / open / __import__ / getattr / globals ...). It then runs with a reduced
builtins table.
ISOLATION (RVJC2 B4): a skill now RUNS in a separate interpreter (python3 -I -S: no site-packages, no script directory or current directory on the path),
with an EMPTY environment (no keys, no tokens), an empty temporary working directory, CPU / memory / output limits and a timeout. It cannot import or
patch our modules (they are not on its path and live in another process) and it never sees the bot's environment. It is still not a jail: the child can
reach the standard library and, through it, files and the network of the host; that is why skills stay outside the auto-ship zone.
"""
from __future__ import annotations

import ast
import builtins
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jarvis_skills")
ALLOWED_IMPORTS = frozenset({"json", "math", "re", "datetime", "statistics", "collections", "itertools", "functools", "string", "textwrap", "decimal",
                             "fractions", "typing", "dataclasses", "enum", "operator", "bisect", "heapq"})
DENIED_NAMES = frozenset({"eval", "exec", "compile", "open", "__import__", "getattr", "setattr", "delattr", "globals", "locals", "vars", "input", "breakpoint",
                          "memoryview", "help", "exit", "quit", "type", "object", "super", "classmethod", "staticmethod", "property"})
SAFE_BUILTINS = {n: getattr(builtins, n) for n in ("abs", "all", "any", "bool", "dict", "divmod", "enumerate", "filter", "float", "frozenset", "int", "isinstance",
                                                   "len", "list", "map", "max", "min", "pow", "range", "repr", "reversed", "round", "set", "sorted", "str", "sum",
                                                   "tuple", "zip", "ValueError", "KeyError", "TypeError", "Exception", "print", "chr", "ord", "hash", "iter", "next",
                                                   "slice", "format", "bin", "hex", "oct", "callable", "issubclass", "IndexError", "ZeroDivisionError", "StopIteration")}
NAME = re.compile(r"^[a-z][a-z0-9_]{0,59}$")


class SkillRefused(Exception):
    pass


def check_source(src: str, name: str = "skill") -> ast.Module:
    tree = ast.parse(src, filename=name)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module or ""]
            if isinstance(node, ast.ImportFrom) and node.level:
                raise SkillRefused(f"{name}: relative import")
            for m in mods:
                if m.split(".")[0] not in ALLOWED_IMPORTS:
                    raise SkillRefused(f"{name}: import of {m!r} is not allowed")
        elif isinstance(node, ast.Name) and (node.id in DENIED_NAMES or node.id.startswith("__")):
            raise SkillRefused(f"{name}: name {node.id!r} is not allowed")
        elif isinstance(node, ast.Attribute) and (node.attr.startswith("_")):
            raise SkillRefused(f"{name}: private / dunder attribute {node.attr!r} is not allowed")
        elif isinstance(node, (ast.Global, ast.Nonlocal, ast.AsyncFunctionDef, ast.Await)):
            raise SkillRefused(f"{name}: {type(node).__name__} is not allowed")
    if not any(isinstance(n, ast.FunctionDef) and n.name == "run" for n in tree.body):
        raise SkillRefused(f"{name}: no run(payload) function")
    return tree


def _safe_import(name, globals=None, locals=None, fromlist=(), level=0):
    if level or name.split(".")[0] not in ALLOWED_IMPORTS:
        raise SkillRefused(f"import of {name!r} is not allowed")
    return __import__(name, globals, locals, fromlist, level)


TIMEOUT_S = 10
MAX_OUTPUT = 200_000
# The child: the same reduced builtins and import allowlist, then run(payload) -> JSON on stdout. It gets the source, never a module of ours.
CHILD = r"""
import builtins, json, sys
req = json.loads(sys.stdin.read())
allowed = frozenset(req["allowed"])
def _imp(name, globals=None, locals=None, fromlist=(), level=0):
    if level or name.split(".")[0] not in allowed:
        raise ImportError("import of %r is not allowed" % name)
    return __import__(name, globals, locals, fromlist, level)
safe = {n: getattr(builtins, n) for n in req["builtins"]}
safe["__import__"] = _imp
env = {"__builtins__": safe, "__name__": "jarvis_skill_" + req["name"]}
try:
    exec(compile(req["src"], "<jarvis_skill %s>" % req["name"], "exec"), env)
    out = env["run"](req["payload"])
    sys.stdout.write(json.dumps({"ok": True, "out": out}))
except BaseException as e:
    sys.stdout.write(json.dumps({"ok": False, "err": type(e).__name__ + ": " + str(e)[:300]}))
"""


def _limits(cpu_s: int = TIMEOUT_S):  # in the child, before exec: CPU seconds, address space, no core files, file size
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (cpu_s, cpu_s))
        resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))
    except Exception:
        pass


def run_isolated(src: str, name: str, payload: dict, timeout_s: int = TIMEOUT_S) -> dict:
    """Run a CHECKED skill source in a separate interpreter with an empty environment. Returns run()'s dict or raises SkillRefused."""
    req = json.dumps({"src": src, "name": name, "payload": payload, "allowed": sorted(ALLOWED_IMPORTS), "builtins": sorted(SAFE_BUILTINS)}, default=str)
    with tempfile.TemporaryDirectory(prefix="jarvis_skill_") as tmp:
        try:
            p = subprocess.run([sys.executable, "-I", "-S", "-c", CHILD], input=req, capture_output=True, text=True, env={}, cwd=tmp,
                               timeout=timeout_s + 5, preexec_fn=(lambda: _limits(timeout_s)) if os.name == "posix" else None)
        except subprocess.TimeoutExpired:
            raise SkillRefused(f"{name}: timed out")
    if len(p.stdout) > MAX_OUTPUT:
        raise SkillRefused(f"{name}: output too large")
    try:
        res = json.loads(p.stdout or "{}")
    except ValueError:
        raise SkillRefused(f"{name}: no result (exit {p.returncode})")
    if not res.get("ok"):
        raise SkillRefused(f"{name}: {res.get('err') or 'failed'}")
    return res.get("out")


def load_source(src: str, name: str = "skill"):
    """Check the source (refuses before anything runs) and return run(payload), which executes in the isolated child process."""
    check_source(src, name)
    return lambda payload: run_isolated(src, name, payload)


def load(name: str, root: str = ROOT):
    if not NAME.match(name or ""):
        raise SkillRefused("bad skill name")
    with open(os.path.join(root, name + ".py"), encoding="utf-8") as f:
        return load_source(f.read(), name)


def run(name: str, payload: dict, root: str = ROOT) -> dict:
    out = load(name, root)(dict(payload or {}))
    if not isinstance(out, dict):
        raise SkillRefused(f"{name}: run() must return a dict")
    return out
