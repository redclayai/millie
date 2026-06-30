#!/usr/bin/env python3
# Render the Millie app icon ("Destello + M" — the SUGGESTED mark from the
# handoff): cream squircle, dark-brown M cradling a pink spark.
import os, math
from PIL import Image, ImageDraw

OUT = "/tmp/MillieIcon.iconset"
os.makedirs(OUT, exist_ok=True)
SS = 4096                      # supersample master, downsampled per size
CREAM = (0xFB, 0xF3, 0xE5, 255)
BROWN = (0x3A, 0x2A, 0x20, 255)
PINK  = (0xE0, 0x50, 0x6A, 255)

def bez(p0, p1, p2, p3, P, n=28):
    out = []
    for i in range(n + 1):
        t = i / n; mt = 1 - t
        x = mt**3*p0[0] + 3*mt*mt*t*p1[0] + 3*mt*t*t*p2[0] + t**3*p3[0]
        y = mt**3*p0[1] + 3*mt*mt*t*p1[1] + 3*mt*t*t*p2[1] + t**3*p3[1]
        out.append(P(x, y))
    return out

def master():
    s = SS / 1024.0
    img = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    margin = 40 * s
    B = 1024 * s - 2 * margin
    r = 211 * s
    d.rounded_rectangle([margin, margin, margin + B, margin + B], radius=r, fill=CREAM)
    # glyph: 100x100 viewBox shown at 62% of the tile, centered (matches handoff .g)
    gs = 0.62 * B
    gx0 = margin + (B - gs) / 2
    gy0 = margin + (B - gs) / 2
    def P(gx, gy):
        return (gx0 + gx / 100.0 * gs, gy0 + gy / 100.0 * gs)
    pw = 12 / 100.0 * gs
    pts = [P(22, 76), P(22, 26), P(50, 60), P(78, 26), P(78, 76)]
    d.line(pts, fill=BROWN, width=int(round(pw)), joint="curve")
    rc = pw / 2
    for v in pts:  # round caps + joins
        d.ellipse([v[0]-rc, v[1]-rc, v[0]+rc, v[1]+rc], fill=BROWN)
    poly = []
    poly += bez((50,29),(51.5,39),(52,39.5),(63,42), P)
    poly += bez((63,42),(52,44.5),(51.5,45),(50,55), P)
    poly += bez((50,55),(48.5,45),(48,44.5),(37,42), P)
    poly += bez((37,42),(48,39.5),(48.5,39),(50,29), P)
    d.polygon(poly, fill=PINK)
    return img

M = master()
names = {16:"16x16",32:["16x16@2x","32x32"],64:"32x32@2x",128:"128x128",
         256:["128x128@2x","256x256"],512:["256x256@2x","512x512"],1024:"512x512@2x"}
for px, nm in names.items():
    im = M.resize((px, px), Image.LANCZOS)
    for n in ([nm] if isinstance(nm, str) else nm):
        im.save(os.path.join(OUT, f"icon_{n}.png"))
print("iconset written:", sorted(os.listdir(OUT)))
