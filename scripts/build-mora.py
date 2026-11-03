#!/usr/bin/env python3
"""Builds the approximate grid MORA bundled with the iPad app (Resources/Basemap/mora.geojson).

Grid MORA is the lowest altitude that clears the highest terrain of a 1° x 1° cell by 1,000 ft (2,000 ft where the
terrain is above 5,000 ft), rounded up to the next 100 ft. This is a sim aid: it is computed from open terrain
elevation only (AWS Terrain Tiles, "Terrarium" encoding, zoom 7), without obstacles, so treat it as approximate and
never use it for real navigation. Values are shown in hundreds of feet on the map (214 = 21,400 ft).

Usage: python3 -I scripts/build-mora.py          (downloads about 60 MB of tiles once; they are cached)
"""
import json
import math
import os
import struct
import sys
import tempfile
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "ios", "SimPilotEFB", "Resources", "Basemap", "mora.geojson")
CACHE = os.path.join(tempfile.gettempdir(), "simpilot-mora-tiles")
URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
Z = 7
# Europe, the Mediterranean, North Africa, the Middle East and the North Atlantic.
LAT_MIN, LAT_MAX, LON_MIN, LON_MAX = 25, 72, -35, 60
FT_PER_M = 3.280839895


def tile_range():
    n = 2 ** Z

    def x_of(lon):
        return int((lon + 180) / 360 * n)

    def y_of(lat):
        r = math.radians(lat)
        return int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)

    return x_of(LON_MIN), x_of(LON_MAX - 1e-9), y_of(LAT_MAX), y_of(LAT_MIN + 1e-9)


def fetch(x, y):
    path = os.path.join(CACHE, f"{Z}-{x}-{y}.png")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        with urllib.request.urlopen(URL.format(z=Z, x=x, y=y), timeout=60) as r:
            data = r.read()
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    with open(path, "rb") as f:
        return f.read()


def decode_png(data):
    """8-bit RGB / RGBA PNG, not interlaced -> (width, height, bytes per pixel, rows of bytes)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, width, height, color = 8, [], 0, 0, 0
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and color in (2, 6) and interlace == 0, "unsupported PNG"
        elif kind == b"IDAT":
            idat.append(body)
        pos += 12 + length
    bpp = 3 if color == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for r in range(height):
        f = raw[r * (stride + 1)]
        line = bytearray(raw[r * (stride + 1) + 1:(r + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def lat_of_row(y_pixel, n_pixels):
    """Latitude of a (fractional) pixel row of the whole world map."""
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y_pixel / n_pixels))))


def mora_hundreds_ft(max_m):
    # The 1.2 km tiles smooth sharp peaks (Mont Blanc comes out about 2 % low): add 4 % so the value errs on the high side.
    ft = max(0.0, max_m) * 1.04 * FT_PER_M
    clearance = 1000 if ft <= 5000 else 2000
    return int(math.ceil((ft + clearance) / 100.0))


def main():
    x0, x1, y0, y1 = tile_range()
    tiles = [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
    print(f"{len(tiles)} tiles at zoom {Z} (cached in {CACHE})")
    cells = {}  # (lat floor, lon floor) -> highest elevation in metres
    n_pixels = 256 * 2 ** Z
    done = 0
    with ThreadPoolExecutor(max_workers=12) as pool:
        for (x, y), data in zip(tiles, pool.map(lambda t: fetch(*t), tiles)):
            w, h, bpp, rows = decode_png(data)
            lon_cells = []
            for px in range(w):
                lon = (x * 256 + px + 0.5) / n_pixels * 360 - 180
                lon_cells.append(math.floor(lon))
            for py in range(h):
                lat = lat_of_row(y * 256 + py + 0.5, n_pixels)
                lat_cell = math.floor(lat)
                if not (LAT_MIN <= lat_cell < LAT_MAX):
                    continue
                row = rows[py]
                start = 0
                while start < w:
                    lon_cell = lon_cells[start]
                    end = start
                    while end < w and lon_cells[end] == lon_cell:
                        end += 1
                    if LON_MIN <= lon_cell < LON_MAX:
                        # Terrarium: metres = R * 256 + G + B / 256 - 32768
                        best = max(row[bpp * i] * 256 + row[bpp * i + 1] for i in range(start, end)) - 32768
                        key = (lat_cell, lon_cell)
                        if best > cells.get(key, -32768):
                            cells[key] = best
                    start = end
            done += 1
            if done % 100 == 0:
                print(f"  {done}/{len(tiles)}")
    features = []
    for lat in range(LAT_MIN, LAT_MAX):
        for lon in range(LON_MIN, LON_MAX):
            if (lat, lon) not in cells:
                continue
            features.append({
                "type": "Feature",
                "properties": {"m": mora_hundreds_ft(cells[(lat, lon)])},
                "geometry": {"type": "Point", "coordinates": [lon + 0.5, lat + 0.5]},
            })
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({"type": "FeatureCollection", "features": features}, f, separators=(",", ":"))
    print(f"{len(features)} cells -> {OUT} ({os.path.getsize(OUT) // 1024} KB)")


if __name__ == "__main__":
    sys.exit(main())
