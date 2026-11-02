#!/usr/bin/env python3
"""把订阅服务的品牌图标抓成本地资源，并生成 templates.json。

图标来源（都是 CDN 上的开源集合，按顺序回退）：
  logos    Iconify `logos` 集合（SVG Logos，全彩品牌标）
  si-11    simple-icons@11（含被新版下架的商标）
  si-9     simple-icons@9（补充 hulu 等）
  arc      Arcticons（Android 应用图标，含国内 App）

输出：
  Sources/WSFeatures/Resources/Brands.xcassets/<id>.imageset/*.svg
  Sources/WSFeatures/Resources/templates.json
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = "/tmp/ws-brands-cache"
ASSETS = os.path.join(ROOT, "packages/WSubscriptionKit/Sources/WSFeatures/Resources/Brands.xcassets")
TEMPLATES = os.path.join(ROOT, "packages/WSubscriptionKit/Sources/WSCore/Resources/templates.json")
SHARED = os.path.join(ROOT, "shared/catalog")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from services import SERVICES  # noqa: E402


def load(name, url):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name + ".json")
    if not os.path.exists(path):
        subprocess.run(["curl", "-sSfL", "-o", path, url], check=True)
    with open(path) as handle:
        return json.load(handle)


def iconify_index():
    data = load("logos", "https://cdn.jsdelivr.net/npm/@iconify-json/logos@1/icons.json")
    icons = {}
    for key, value in data["icons"].items():
        icons[key] = {
            "body": value["body"],
            "w": value.get("width", data.get("width", 24)),
            "h": value.get("height", data.get("height", 24)),
            "mono": "currentColor" in value["body"],
        }
    return icons


def arcticons_index():
    data = load("arcticons", "https://cdn.jsdelivr.net/npm/@iconify-json/arcticons@1/icons.json")
    icons = {}
    for key, value in data["icons"].items():
        icons[key] = {
            "body": value["body"],
            "w": value.get("width", data.get("width", 24)),
            "h": value.get("height", data.get("height", 24)),
            "mono": "currentColor" in value["body"],
        }
    return icons


DI_BASE = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg"


def dashboard_icon(slug):
    """dashboard-icons：全彩，和各家 App 图标基本一致。"""
    if not slug:
        return None
    path = os.path.join(CACHE, f"di-{slug}.svg")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        url = f"{DI_BASE}/{slug}.svg"
        result = subprocess.run(["curl", "-sSfL", "-o", path, url], capture_output=True)
        if result.returncode != 0:
            return None
    with open(path, encoding="utf-8") as handle:
        svg = handle.read()
    if "<svg" not in svg:
        return None
    return svg


def simple_icon(slug, version):
    path = os.path.join(CACHE, f"si-{version}-{slug}.svg")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        url = f"https://cdn.jsdelivr.net/npm/simple-icons@{version}/icons/{slug}.svg"
        result = subprocess.run(["curl", "-sSfL", "-o", path, url], capture_output=True)
        if result.returncode != 0:
            return None
    with open(path, encoding="utf-8") as handle:
        svg = handle.read()
    match = re.search(r'<path d="([^"]+)"', svg)
    if not match:
        return None
    return {"body": f'<path d="{match.group(1)}"/>', "w": 24, "h": 24, "mono": True}


def wrap(body, w, h, mono, color):
    body = body.replace('currentColor', f'#{color}')
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'width="{w}" height="{h}">{body}</svg>'
    )


def normalize(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def resolve(entry, logos, arc):
    """按优先级取图标，返回 (svg, source, style)。style=color 表示自带背景的全彩标。"""
    color = entry["hex"].lstrip("#")

    # 1) dashboard-icons：全彩，直接铺满方块
    slugs = []
    if entry.get("di"):
        slugs.append(entry["di"])
    slugs.append(entry["id"])
    for slug in slugs:
        svg = dashboard_icon(slug)
        if svg:
            return svg, f"di:{slug}", "color"

    # 2) Iconify logos：全彩或单色
    for candidate in entry.get("icon", []):
        source, _, slug = candidate.partition(":")
        if source == "logos" and slug in logos:
            item = logos[slug]
            style = "mono" if item["mono"] else "color"
            fill = "FFFFFF" if style == "mono" else color
            return wrap(item["body"], item["w"], item["h"], style == "mono", fill), f"logos:{slug}", style
        if source == "arc" and slug in arc:
            item = arc[slug]
            return wrap(item["body"], item["w"], item["h"], True, "FFFFFF"), f"arc:{slug}", "mono"
        if source == "si":
            for version in ("11.15.0", "9.21.0"):
                item = simple_icon(slug, version)
                if item:
                    return wrap(item["body"], 24, 24, True, "FFFFFF"), f"si{version[0]}:{slug}", "mono"
    return None, None, None


def main():
    logos = iconify_index()
    arc = arcticons_index()
    os.makedirs(ASSETS, exist_ok=True)

    catalog_contents = {"info": {"author": "xcode", "version": 1}}
    with open(os.path.join(ASSETS, "Contents.json"), "w") as handle:
        json.dump(catalog_contents, handle, indent=2)

    templates = []
    missing = []
    for entry in SERVICES:
        svg, source, style = resolve(entry, logos, arc)
        brand = None
        if svg:
            brand = entry["id"]
            # 平台无关副本，供 Android 端复用
            shared_dir = os.path.join(SHARED, "brands")
            os.makedirs(shared_dir, exist_ok=True)
            with open(os.path.join(shared_dir, f"{brand}.svg"), "w", encoding="utf-8") as handle:
                handle.write(svg)
            folder = os.path.join(ASSETS, f"{brand}.imageset")
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, f"{brand}.svg"), "w", encoding="utf-8") as handle:
                handle.write(svg)
            with open(os.path.join(folder, "Contents.json"), "w") as handle:
                json.dump({
                    "images": [{"filename": f"{brand}.svg", "idiom": "universal"}],
                    "info": {"author": "xcode", "version": 1},
                    "properties": {"preserves-vector-representation": True},
                }, handle, indent=2)
        else:
            missing.append(entry["id"])

        templates.append({
            "id": entry["id"],
            "name": entry["name"],
            "vendor": entry.get("vendor", ""),
            "categoryID": entry["category"],
            "brand": brand,
            "style": style or "mono",
            "hex": entry["hex"],
            "symbol": entry.get("symbol", "creditcard.fill"),
            "defaultCycle": {"kind": entry.get("cycle", "monthly")},
            "aliases": entry.get("aliases", []),
            "popularity": entry.get("popularity", 40),
        })

    payload = {"templates": templates}
    with open(TEMPLATES, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)

    os.makedirs(SHARED, exist_ok=True)
    with open(os.path.join(SHARED, "services.json"), "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "services": templates}, handle, ensure_ascii=False, indent=1)

    print(f"共 {len(SERVICES)} 个服务，图标命中 {len(SERVICES) - len(missing)}，缺失 {len(missing)}")
    if missing:
        print("缺图标：", ", ".join(missing))


if __name__ == "__main__":
    main()
