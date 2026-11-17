"""
Restricted loader for Jarvis's auto-ship zone skills (jarvis_skills/*.py, ops/PROTECTED_PATHS.json self_edit.auto_ship_zone). PROTECTED file.

A skill is plain Python with `def run(payload: dict) -> dict`. It is NOT imported as a module: the loader parses it, refuses it unless every import is on
ALLOWED_IMPORTS (pure standard library, no I/O, no os / sys / importlib / socket / subprocess, no hq_* or any protected module), and refuses names and
attributes that reach the interpreter's internals (dunder names, eval / exec / open / __import__ / getattr / globals ...). It then runs with a reduced
builtins table. So a skill Jarvis writes can compute, but cannot import or patch a protected module, touch files, the network or the database.
Defence in depth, not a perfect sandbox: the zone is still reviewed (independent reviewer + CI) before it ships.
"""
from __future__ import annotations

import ast
import builtins
import os
import re

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


def load_source(src: str, name: str = "skill"):
    tree = check_source(src, name)
    env = {"__builtins__": {**SAFE_BUILTINS, "__import__": _safe_import}, "__name__": f"jarvis_skill_{name}"}
    exec(compile(tree, f"<jarvis_skill {name}>", "exec"), env)   # noqa: S102 - checked source, reduced builtins (see module docstring)
    return env["run"]


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
