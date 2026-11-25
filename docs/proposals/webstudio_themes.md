# Proposal: let `/site new` choose a Web Studio theme (owner approval: `hq_webstudio.py` is protected)

Status: proposal only. Nothing here is applied.

## Why
The `maison` theme (black, wine, metallic gold) is in the AstroWind template and is selected per site with `"theme": "maison"`
in `sites/<slug>/site.json`. Today an owner or agent adds that key in the site's pull request by hand. Letting `/site new` take it,
and having `validate()` reject unknown themes, makes it a first-class option for the bot.

## Exact change (`hq_webstudio.py`)
```diff
 TEMPLATES = {
     "astrowind": {
         "path": "sites/_templates/astrowind", "upstream": "https://github.com/onwidget/astrowind", "commit": "14e1a691f80548dcc36370847b1a02c0d0b12821",
-        "license": "MIT", "variants": ("futuristic", "local"),
+        "license": "MIT", "variants": ("futuristic", "local"), "themes": {"futuristic": ("maison",)},
@@ def validate(site: dict) -> list[str]:
     elif site.get("variant") not in t["variants"]:
         p.append(f"variant must be one of {', '.join(t['variants'])}")
+    elif site.get("theme") is not None and site["theme"] not in t.get("themes", {}).get(site["variant"], ()):
+        p.append(f"theme {site['theme']!r} is not available for {site.get('template')}/{site['variant']}")
@@ def skeleton(slug, office, template, variant, brand, pricing=None, legal=None) -> dict:
-    return {"schema": 1, "slug": slug, "version": 1, "office": office, "template": template, "variant": variant, "brand": dict(brand),
+    variant, _, theme = variant.partition("+")
+    return {"schema": 1, "slug": slug, "version": 1, "office": office, "template": template, "variant": variant, **({"theme": theme} if theme else {}),
+            "brand": dict(brand),
```
`/site new acme acme astrowind/futuristic+maison Acme | Ottawa | #7a1428 #c9a24a | brief` then drafts a maison site.
`draft()` passes `variant` through `skeleton()`, so the `+theme` suffix needs no other change; `USAGE` gains `<template>/<variant>[+theme]`.

## Tests to add (`test_hq_webstudio.py`, protected)
- `validate` accepts `theme: "maison"` on `astrowind/futuristic`, rejects it on `astrowind/local` and rejects `theme: "x"`.
- `skeleton(..., "futuristic+maison", ...)` gives `variant == "futuristic"` and `theme == "maison"`.

## Rollback
Revert the commit; sites that carry `"theme": "maison"` keep building (the template reads the key; validate ignores it today).
