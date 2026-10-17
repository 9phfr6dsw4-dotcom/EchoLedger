#!/usr/bin/env python3
"""Build the offline catalog from pinned public artwork, never from transaction data.

Development dependencies: pip install cairosvg==2.8.2 Pillow==13.0.0
Usage: python3 Scripts/generate-merchant-icons.py [path/to/simple-icons-13.21.0.tgz]
Without an archive argument, download the pinned npm source archive.
Use --supplement-only to refresh consumer artwork without rebuilding Simple Icons.
"""
import argparse
import concurrent.futures
import collections
import hashlib
import io
import json
import pathlib
import re
import tarfile
import unicodedata
import urllib.request

import cairosvg
from PIL import Image, ImageChops

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


def consumer_brands(cache):
    manifest = json.loads((ROOT / "Scripts/merchant-icon-supplement.json").read_text())
    cache.mkdir(parents=True, exist_ok=True)

    def render(brand):
        source_url = brand["source"]
        collection = manifest["collections"][brand["collection"]]
        if not re.fullmatch(r"[0-9a-f]{40}", collection["revision"]):
            raise ValueError("Consumer artwork must pin a full Git revision.")
        expected_root = ("https://raw.githubusercontent.com/" + collection["repository"]
                         + "/" + collection["revision"] + "/")
        if not source_url.startswith(expected_root):
            raise ValueError("Consumer artwork must use the pinned public collection.")
        if not re.fullmatch(r"consumer-[a-z0-9-]+", brand["asset"]):
            raise ValueError("Consumer asset filenames must be plain names.")
        cached = cache / brand["sourceSHA256"]
        source = (cached.read_bytes() if cached.exists() else
                  urllib.request.urlopen(source_url, timeout=60).read())
        if hashlib.sha256(source).hexdigest() != brand["sourceSHA256"]:
            raise ValueError(f"Consumer source checksum mismatch: {brand['asset']}")
        if "originalSourceSHA1" in brand and hashlib.sha1(source).hexdigest() != brand["originalSourceSHA1"]:
            raise ValueError(f"Original artwork provenance mismatch: {brand['asset']}")
        cached.write_bytes(source)
        if source_url.endswith(".svg"):
            # All selected SVGs are standalone: do not fetch linked images or fonts.
            if re.search(rb'(?:href\s*=\s*[\"\'](?!#)|url\(\s*(?!#))', source):
                raise ValueError(f"External SVG reference: {brand['asset']}")
            source_image = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=source,
                                                               output_width=768, output_height=768)))
        else:
            source_image = Image.open(io.BytesIO(source))
        image = source_image.convert("RGBA")
        # Trim empty/white margins; preserve proportions, multicolor marks, and interior white.
        background = Image.new("RGBA", image.size, "white")
        background.alpha_composite(image)
        bounds = ImageChops.difference(background.convert("RGB"),
                                      Image.new("RGB", image.size, "white")).getbbox()
        if bounds is None:
            raise ValueError(f"Blank consumer artwork: {brand['asset']}")
        image = image.crop(bounds)
        image.thumbnail((192, 192), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (192, 192))
        canvas.alpha_composite(image, ((192 - image.width) // 2, (192 - image.height) // 2))
        buffer = io.BytesIO()
        canvas.save(buffer, format="PNG")
        png = buffer.getvalue()
        (OUTPUT / (brand["asset"] + ".png")).write_bytes(png)
        return {**brand, "pngSHA256": hashlib.sha256(png).hexdigest()}

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        return list(pool.map(render, manifest["brands"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", nargs="?", type=pathlib.Path)
    parser.add_argument("--supplement-only", action="store_true")
    parser.add_argument("--source-cache", type=pathlib.Path,
                        default=pathlib.Path("/tmp/echoledger-consumer-source"))
    args = parser.parse_args()
    if args.supplement_only:
        catalog = json.loads((OUTPUT / "catalog.json").read_text())
        write_catalog([b for b in catalog if not b["asset"].startswith("consumer-")]
                      + consumer_brands(args.source_cache))
        return
    archive = (args.archive.read_bytes() if args.archive else
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
    catalog += consumer_brands(args.source_cache)
    write_catalog(catalog)
    (OUTPUT / "LICENSE-simple-icons.md").write_bytes(license_text)
    (OUTPUT / "DISCLAIMER-simple-icons.md").write_bytes(disclaimer)
    print(f"Source archive SHA-256: {hashlib.sha256(archive).hexdigest()}", flush=True)


def write_catalog(catalog):
    names = set()
    assets = set()
    for brand in catalog:
        if brand["asset"] in assets:
            raise ValueError(f"Duplicate asset: {brand['asset']}")
        assets.add(brand["asset"])
        for name in brand["names"]:
            normalized = key(name)
            if normalized in names:
                raise ValueError(f"Ambiguous merchant name: {name}")
            names.add(normalized)
    expected = {entry["asset"] + ".png" for entry in catalog}
    for old in OUTPUT.glob("*.png"):
        if old.name not in expected:
            old.unlink()
    (OUTPUT / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"Generated {len(catalog)} brand marks / {len(names)} exact merchant names.", flush=True)


if __name__ == "__main__":
    main()
