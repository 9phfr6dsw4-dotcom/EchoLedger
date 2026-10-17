#!/usr/bin/env python3
"""Build the offline catalog from pinned public artwork, never from transaction data.

Development dependency: pip install cairosvg==2.8.2
Usage: python3 Scripts/generate-merchant-icons.py [path/to/simple-icons-13.21.0.tgz]
Without an archive argument, download the pinned npm source archive.
"""
import concurrent.futures
import collections
import hashlib
import io
import json
import pathlib
import re
import sys
import tarfile
import unicodedata
import urllib.request

import cairosvg

VERSION = "13.21.0"
ARCHIVE_URL = f"https://registry.npmjs.org/simple-icons/-/simple-icons-{VERSION}.tgz"
ARCHIVE_SHA256 = "33e4e8c92f51bac4c4e88c3b2d98ad2b4faa91a00cbfdf24c894e8691a2e63ea"
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/EchoLedgerCore/Resources/MerchantIcons"
ALIASES = {
    "Amazon": ["Amazon Prime"],
    "Apple": ["Apple Store", "Apple Services", "Apple Card Installments", "iCloud+"],
    "Walmart": ["Walmart Grocery"],
    "YouTube": ["YouTube TV", "YouTube Premium"],
    "Google": ["Google One"],
    "Uber": ["Uber One"],
    "DoorDash": ["DashPass"],
    "Delta": ["Delta Air Lines"],
    "Marriott": ["Marriott Hotels"],
    "Hilton": ["Hilton Hotels"],
}


def key(name):
    return " ".join("".join(c for c in unicodedata.normalize("NFD", name.casefold())
                            if not unicodedata.combining(c)).replace("’", "'").split())


def slug(icon):
    if "slug" in icon:
        return icon["slug"]
    replacements = {"+": "plus", ".": "dot", "&": "and", "đ": "d", "ħ": "h",
                    "ı": "i", "ĸ": "k", "ŀ": "l", "ł": "l", "ß": "ss", "ŧ": "t"}
    name = "".join(replacements.get(c, c) for c in icon["title"].lower())
    return re.sub("[^a-z0-9]", "", unicodedata.normalize("NFD", name))


def main():
    archive = (pathlib.Path(sys.argv[1]).read_bytes() if len(sys.argv) > 1 else
               urllib.request.urlopen(ARCHIVE_URL, timeout=60).read())
    if hashlib.sha256(archive).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("The source archive does not match the pinned version's SHA-256.")
    with tarfile.open(fileobj=io.BytesIO(archive)) as package:
        icons = json.load(package.extractfile("package/_data/simple-icons.json"))["icons"]
        # Other marks carry separate licenses. This catalog includes only the collection's
        # CC0 artwork and explicit CC0 marks, keeping redistribution consistent.
        icons = [i for i in icons if i.get("license", {}).get("type", "CC0-1.0") == "CC0-1.0"]
        counts = collections.Counter(key(i["title"]) for i in icons)
        # Some unrelated brands share a title; a name alone cannot identify those safely.
        icons = [i for i in icons if counts[key(i["title"])] == 1]
        sources = [(i, package.extractfile(f"package/icons/{slug(i)}.svg").read()) for i in icons]
        license_text = package.extractfile("package/LICENSE.md").read()
        disclaimer = package.extractfile("package/DISCLAIMER.md").read()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    official_names = {key(i["title"]): slug(i) for i in icons}
    used_names = dict(official_names)
    names_by_slug = {}
    for icon in icons:
        asset = slug(icon)
        names = [icon["title"]]
        candidates = icon.get("aliases", {}).get("aka", []) + ALIASES.get(icon["title"], [])
        for name in candidates:
            normalized = key(name)
            if normalized not in used_names:
                used_names[normalized] = asset
                names.append(name)
        names_by_slug[asset] = names

    def render(item):
        icon, source = item
        asset = slug(icon)
        colored = source.replace(b"<svg ", f'<svg fill="#{icon["hex"]}" '.encode(), 1)
        png = cairosvg.svg2png(bytestring=colored, output_width=192, output_height=192)
        (OUTPUT / f"{asset}.png").write_bytes(png)
        return {"asset": asset, "names": names_by_slug[asset],
                "source": f"https://raw.githubusercontent.com/simple-icons/simple-icons/{VERSION}/icons/{asset}.svg",
                "upstreamSource": icon["source"], "hex": icon["hex"],
                "svgSHA256": hashlib.sha256(source).hexdigest(),
                "pngSHA256": hashlib.sha256(png).hexdigest()}

    # Cairo's font-free, path-only SVG conversion is independent for each mark.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        catalog = list(pool.map(render, sources))
    expected = {entry["asset"] + ".png" for entry in catalog}
    for old in OUTPUT.glob("*.png"):
        if old.name not in expected:
            old.unlink()
    (OUTPUT / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    (OUTPUT / "LICENSE-simple-icons.md").write_bytes(license_text)
    (OUTPUT / "DISCLAIMER-simple-icons.md").write_bytes(disclaimer)
    print(f"Generated {len(catalog)} brand marks / {len(used_names)} exact merchant names.", flush=True)
    print(f"Source archive SHA-256: {hashlib.sha256(archive).hexdigest()}", flush=True)


if __name__ == "__main__":
    main()
