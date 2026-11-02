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
    return normalize_square(svg)


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


def normalize_square(svg):
    """把所有图标规整成正方形画布：等比居中补透明边，绝不裁切内容。
    这样 UI 端无论 scaledToFit 还是 scaledToFill 都不会切边或错位。"""
    match = re.search(r'viewBox="([^"]+)"', svg)
    if match:
        parts = [float(v) for v in re.split(r"[ ,]+", match.group(1).strip()) if v]
        if len(parts) != 4:
            return svg
        min_x, min_y, width, height = parts
    else:
        width_match = re.search(r'width="([\d.]+)', svg)
        height_match = re.search(r'height="([\d.]+)', svg)
        if not (width_match and height_match):
            return svg
        min_x = min_y = 0.0
        width = float(width_match.group(1))
        height = float(height_match.group(1))
        svg = re.sub(r"<svg", f'<svg viewBox="0 0 {width:g} {height:g}"', svg, count=1)

    if width <= 0 or height <= 0:
        return svg

    side = max(width, height)
    new_view = f"{min_x - (side - width) / 2:g} {min_y - (side - height) / 2:g} {side:g} {side:g}"
    svg = re.sub(r'viewBox="[^"]+"', f'viewBox="{new_view}"', svg, count=1)
    svg = re.sub(r"\swidth=\"[^\"]+\"", "", svg, count=1)
    svg = re.sub(r"\sheight=\"[^\"]+\"", "", svg, count=1)
    return svg


def wrap(body, w, h, mono, color):
    body = body.replace('currentColor', f'#{color}')
    return normalize_square(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">{body}</svg>'
    )


def normalize(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


COMPOSER = os.path.join(CACHE, "compose_icon")


def ensure_composer():
    if os.path.exists(COMPOSER):
        return COMPOSER
    os.makedirs(CACHE, exist_ok=True)
    subprocess.run(["swiftc", "-O", os.path.join(ROOT, "tools/compose_icon.swift"), "-o", COMPOSER],
                   check=True, capture_output=True)
    return COMPOSER


def compose(png_path, tile_hex, scale):
    """把纯 logo 合成到品牌底色上，或把自带背景的图标裁成满版。"""
    try:
        subprocess.run([ensure_composer(), png_path, tile_hex, png_path, str(scale)],
                       check=True, capture_output=True)
    except Exception as error:  # 合成失败不影响主流程，保留原始栅格图
        print(f"compose failed: {png_path} {error}")


def rasterize(svg_path, png_path, side=512):
    """用 macOS 的 sips 把 SVG 栅格化，保证运行时所见即所得。"""
    result = subprocess.run(
        ["sips", "-s", "format", "png", svg_path, "--out", png_path,
         "--resampleHeightWidth", str(side), str(side)],
        capture_output=True,
    )
    return result.returncode == 0 and os.path.exists(png_path)


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
            svg_path = os.path.join(folder, f"{brand}.svg")
            with open(svg_path, "w", encoding="utf-8") as handle:
                handle.write(svg)
            png_name = f"{brand}.png"
            png_path = os.path.join(folder, png_name)
            if rasterize(svg_path, png_path):
                # 单色标的图形本身带内边距，放大一点才和全彩图标视觉等大
                compose(png_path, entry.get("tile", entry["hex"]),
                        0.80 if style == "mono" else 0.64)
            with open(os.path.join(folder, "Contents.json"), "w") as handle:
                json.dump({
                    "images": [{"filename": png_name, "idiom": "universal"}],
                    "info": {"author": "xcode", "version": 1},
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
            "tile": entry.get("tile", entry["hex"]),
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
