#!/usr/bin/env python3
"""Measure the last pre-clear frame against the aligned desktop (Pillow)."""
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageChops, ImageStat

root = Path(__file__).resolve().parent.parent
out = root / "Validation/Visuals/Handoff"
font_path = "/System/Library/Fonts/Supplemental/Arial.ttf"
metrics = []
for fixture in ["light", "checker"]:
    original = Image.open(out/f"{fixture}-8-after.png").convert("RGB")
    entry = {"fixture":fixture, "raw_angle":112, "clear_boundary":113, "calibration":115}
    for method in ["before", "after"]:
        frame = Image.open(out/f"{fixture}-5-{method}.png").convert("RGB")
        delta = ImageChops.difference(frame,original)
        stat=ImageStat.Stat(delta)
        histogram=delta.histogram()
        pixels=frame.width*frame.height*3
        entry[method] = {"rms_code_value":math.sqrt(sum(x*x for x in stat.rms)/3),
                         "mean_absolute_code_value":sum(stat.mean)/3,
                         "maximum_code_difference":max(high for low,high in delta.getextrema()),
                         "channel_values_different_by_over_2_percent":100*sum(count for index,count in enumerate(histogram) if index%256>2)/pixels}
    metrics.append(entry)
    canvas=Image.new("RGB",(1260,538),"#10131b")
    draw=ImageDraw.Draw(canvas)
    draw.text((20,16),f"{fixture} / last 1 degree before clear / same Gaussian shader",font=ImageFont.truetype(font_path,23),fill="#e5edf7")
    for column,(method,title,index) in enumerate([("before","BEFORE - abrupt removal",5),("after","AFTER - angle-based handoff",5),("after","CLEAR - aligned original",8)]):
        image=Image.open(out/f"{fixture}-{index}-{method}.png").convert("RGB")
        x=20+column*415
        draw.text((x,60),title,font=ImageFont.truetype(font_path,17),fill="#b9c8dc")
        canvas.paste(image.crop((0,0,200,200)).resize((400,400),Image.Resampling.NEAREST),(x,95))
    draw.text((20,510),"2x nearest-neighbor crop. No extra image filtering. Static residual comparison, not physical latency.",font=ImageFont.truetype(font_path,17),fill="#a4b4c9")
    canvas.save(out/f"{fixture}-comparison.png")

result={"schema":1,"test":"Actual GPU last-integer-angle residual against clear original; no temporal or physical latency claim",
        "handoff_degrees":6,"fixtures":metrics}
(out/"metrics.json").write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
