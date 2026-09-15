#!/usr/bin/env python3
"""Create lossless edge crops, a fixture gallery and code-value edge profiles.

Needs Pillow. Run render-validation.sh first. No captured desktop data is used.
"""
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Validation/Visuals"
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"


def font(size):
    return ImageFont.truetype(FONT, size)


def label(draw, xy, text, size=20, fill="#e5edf7"):
    draw.text(xy, text, font=font(size), fill=fill)


def comparison(name, tilt, crop, scale, destination):
    box_width = (crop[2] - crop[0]) * scale
    box_height = (crop[3] - crop[1]) * scale
    canvas = Image.new("RGB", (box_width * 2 + 60, box_height + 126), "#10131b")
    d = ImageDraw.Draw(canvas)
    label(d, (20, 14), f"{name} / {tilt} deg / identical crop, {scale}x nearest-neighbor", 20)
    for column, (version, title) in enumerate([("old", "SAVED BASELINE - 24 samples"), ("new", "CURRENT - continuous coverage")]):
        image = Image.open(OUT / f"{name}-{tilt}-{version}.png").convert("RGB")
        x = 20 + column * (box_width + 20)
        label(d, (x, 50), title, 17)
        canvas.paste(image.crop(crop).resize((box_width, box_height), Image.Resampling.NEAREST), (x, 82))
    label(d, (20, box_height + 94), "Magnification preserves original pixels; no extra blur or retouching.", 16, "#a6b4c7")
    canvas.save(OUT / destination)


comparison("light", 35, (45, 45, 205, 305), 3, "edge-comparison.png")
comparison("flat", 15, (475, 0, 725, 90), 3, "top-comparison.png")
comparison("checker", 60, (110, 55, 310, 305), 2, "checker-edge-comparison.png")

fixtures = ["light", "dark", "text", "checker", "flat"]
tilts = [0, 5, 15, 35, 60, 80]
sheet = Image.new("RGB", (1260, 1110), "#10131b")
draw = ImageDraw.Draw(sheet)
label(draw, (20, 14), "CURRENT SHADER / fixture and angle matrix", 22)
for col, tilt in enumerate(tilts):
    label(draw, (25 + col * 205, 54), f"{tilt} deg", 18)
for row, fixture in enumerate(fixtures):
    y = 85 + row * 203
    label(draw, (20, y), fixture.upper(), 16)
    for col, tilt in enumerate(tilts):
        image = Image.open(OUT / f"{fixture}-{tilt}-new.png").convert("RGB")
        image.thumbnail((195, 160), Image.Resampling.LANCZOS)
        sheet.paste(image, (20 + col * 205, y + 28))
label(draw, (20, 1068), "Thumbnails only. Use the full-resolution files or enlarged crops to judge banding.", 17)
sheet.save(OUT / "contact-sheet.png")


def smooth(values):
    weights = [1, 4, 6, 4, 1]
    return [sum(values[max(0, min(len(values)-1, i+j-2))]*w for j,w in enumerate(weights))/16
            for i in range(len(values))]


def edge_metrics(values):
    minimum, maximum = min(values), max(values)
    span = maximum - minimum
    normalized = [(x-minimum)/span if span else 0 for x in values]
    derivative = [b-a for a,b in zip(smooth(normalized), smooth(normalized)[1:])]
    # Peaks above 18% of the largest derivative, separated by >=3 pixels.
    peaks = []
    threshold = max(derivative, default=0) * .18
    for i in range(1, len(derivative)-1):
        if derivative[i] > threshold and derivative[i] > derivative[i-1] and derivative[i] >= derivative[i+1]:
            if not peaks or i-peaks[-1] >= 3:
                peaks.append(i)
    def crossing(q):
        return next((i for i,v in enumerate(normalized) if v >= q), None)
    return {"code_value_range": [minimum, maximum], "max_adjacent_code_jump": max([abs(b-a) for a,b in zip(values,values[1:])] or [0]),
            "ten_to_ninety_width_pixels": (crossing(.9) or 0)-(crossing(.1) or 0),
            "derivative_peak_count": len(peaks), "normalized_code_values": normalized}


metrics = []
for tilt in [5, 15, 35, 60, 80]:
    for height_fraction in [.2, .4, .6]:
        pair = {"tilt": tilt, "row_fraction": height_fraction}
        for version in ["old", "new"]:
            image = Image.open(OUT / f"flat-{tilt}-{version}.png").convert("RGB")
            y = int(image.height*height_fraction)
            values = [sum(image.getpixel((x,y)))/3 for x in range(image.width//3)]
            pair[version] = edge_metrics(values)
        metrics.append(pair)

plot = Image.new("RGB", (1260, 420), "#10131b")
draw = ImageDraw.Draw(plot)
label(draw, (20, 14), "Flat fixture / 35 deg / row 20% / actual 8-bit output", 22)
pair = next(x for x in metrics if x["tilt"] == 35 and x["row_fraction"] == .2)
x0, y0, plot_width, plot_height = 65, 64, 1120, 285
draw.line((x0, y0, x0, y0+plot_height, x0+plot_width, y0+plot_height), fill="#657086", width=1)
for q in [0, .25, .5, .75, 1]:
    y=y0+(1-q)*plot_height
    draw.line((x0,y,x0+plot_width,y), fill="#293141")
    label(draw,(10,y-8),str(q),14)
for version,color in [("old", "#ffa764"),("new", "#64d6c6")]:
    values=pair[version]["normalized_code_values"]
    points=[(x0+x/230*plot_width,y0+(1-v)*plot_height) for x,v in enumerate(values[:231])]
    draw.line(points,fill=color,width=3)
label(draw,(85,75),"Baseline",18,"#ffa764")
label(draw,(85,101),"Current",18,"#64d6c6")
label(draw,(65,363),"x: pixel distance from left edge (0-230)   y: normalized output code value",17)
label(draw,(65,389),"This detects sampling steps; it is not a perceptual color or physical optical measurement.",15,"#a6b4c7")
plot.save(OUT/"edge-profile.png")

clear_differences = []
for fixture in fixtures:
    old=Image.open(OUT/f"{fixture}-0-old.png").convert("RGB")
    new=Image.open(OUT/f"{fixture}-0-new.png").convert("RGB")
    # This is a baseline comparison, not a source-identical assertion.
    clear_differences.append({"fixture":fixture,"old_new_max_code_difference":max(abs(a-b) for p,q in zip(old.getdata(),new.getdata()) for a,b in zip(p,q))})
(OUT/"edge-metrics.json").write_text(json.dumps({"schema":1,"source":"Actual Metal output; generated fixtures only",
    "metric_note":"Code values, not linear-light luminance. Derivative peak count uses a 5-pixel binomial filter to suppress 8-bit rounding. Crops are not filtered.",
    "profiles":metrics,"clear_comparisons":clear_differences},indent=2))

gallery = []
for fixture in fixtures:
    for tilt in tilts:
        gallery.append(f'<section><h2>{fixture} · {tilt}°</h2><div class="pair"><figure><figcaption>旧版基线</figcaption><a href="{fixture}-{tilt}-old.png"><img loading="lazy" src="{fixture}-{tilt}-old.png"></a></figure><figure><figcaption>当前版本</figcaption><a href="{fixture}-{tilt}-new.png"><img loading="lazy" src="{fixture}-{tilt}-new.png"></a></figure></div></section>')
html = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>MacBook Duo · 边缘对照</title><style>
body{margin:0;background:#10131b;color:#e5edf7;font:16px/1.6 system-ui}main{max-width:1280px;margin:auto;padding:32px}h1{font-size:32px}p{max-width:900px;color:#b9c4d4}.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}figure{margin:0}img{width:100%;height:auto}figcaption{margin-bottom:8px}section{margin:40px 0}a{color:#8bddff}.hero{max-width:1100px}@media(max-width:650px){.pair{grid-template-columns:1fr}main{padding:16px}}</style><main>
<h1>边缘应当连续融入暗部</h1><p>旧版在纹理越界后返回黑色，再对 24 个离散位置取平均，形成重复斜线。当前版本分别处理内容模糊与边缘覆盖率，使用高斯金字塔和连续高斯覆盖。以下图片由实际 Metal 着色器离屏生成，不是示意图。</p>
<p>斜边放大采用最近邻插值，保留原像素；整图缩略图仅供导航。底部仍较清晰，顶部随深度逐渐模糊。模拟角度是效果倾角，并非传感器的绝对开合角。两张静态 iPhone 参考图仅用于边缘观感，不用于声称复现完整动画曲线。</p>
<img class="hero" src="edge-comparison.png" alt="相同斜边旧版与当前版本放大对照"><img class="hero" src="top-comparison.png" alt="顶部对照"><img src="edge-profile.png" alt="纯色边缘亮度剖面"><img src="contact-sheet.png" alt="全部当前输出">
<p><a href="../../PixPin_2026-09-14_12-03-19.png">参考图一</a> · <a href="../../PixPin_2026-09-14_12-03-45.png">参考图二</a> · <a href="edge-metrics.json">像素剖面数据</a></p>
''' + "\n".join(gallery) + "</main></html>"
(OUT/"index.html").write_text(html)
print(json.dumps({"pairs":len(gallery),"profile_35deg_row_20pct":{v:{k:value for k,value in pair[v].items() if k!="normalized_code_values"} for v in ["old","new"]}},indent=2))
