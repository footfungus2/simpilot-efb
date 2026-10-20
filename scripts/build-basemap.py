#!/usr/bin/env python3
"""Builds the offline Lido-style basemap layers bundled with the iPad app.

Outputs into ios/SimPilotEFB/Resources/Basemap/:
  firs.geojson           FIR/UIR/oceanic boundaries as lines   (VATSpy data project, CC BY-SA 4.0)
  fir-labels.geojson     one label point per FIR ("Langen EDGG")
  country-labels.geojson country name points                    (Natural Earth, public domain)
  airports.geojson       large/medium airports with rank, name, elevation (OurAirports, public domain)
  navaids.geojson        VOR / VOR-DME / VORTAC / TACAN / DME / NDB worldwide        (OurAirports, public domain)
  vatsim-sectors.geojson all VATSpy FIR/sector polygons, for highlighting online CTR/FSS controllers
  vatsim-tracons.geojson SimAware TRACON polygons, for online APP controllers (CC BY-SA 4.0)
  vatsim-index.json      callsign prefix → sector/TRACON ids, UIR members, airport positions
  vatglasses.json        real sector ownership: positions + airspace blocks with owner order
                         (VATGlasses Data Project, CC BY-NC-SA 4.0 — personal, non-commercial use)

Usage: python3 -I scripts/build-basemap.py
"""
import csv
import io
import json
import os
import re
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "ios", "SimPilotEFB", "Resources", "Basemap")

VATSPY = "https://raw.githubusercontent.com/vatsimnetwork/vatspy-data-project/master/"
NE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
OURAIRPORTS = "https://davidmegginson.github.io/ourairports-data/airports.csv"
OURAIRPORTS_NAVAIDS = "https://davidmegginson.github.io/ourairports-data/navaids.csv"
TRACONS = "https://github.com/vatsimnetwork/simaware-tracon-project/releases/latest/download/TRACONBoundaries.geojson"


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def rnd(coords, nd=3):
    """Round nested coordinate arrays to keep the bundle small (3 decimals ≈ 100 m)."""
    if isinstance(coords[0], (int, float)):
        return [round(coords[0], nd), round(coords[1], nd)]
    return [rnd(c, nd) for c in coords]


def write(name: str, features: list) -> None:
    path = os.path.join(OUT, name)
    with open(path, "w") as f:
        json.dump({"type": "FeatureCollection", "features": features}, f, separators=(",", ":"))
    print(f"{name}: {len(features)} features, {os.path.getsize(path) // 1024} KB")


def build_firs() -> None:
    # FIR names from VATSpy.dat: [FIRs] lines are ICAO|Name|CallsignPrefix|BoundaryId
    names = {}
    section = None
    for line in fetch(VATSPY + "VATSpy.dat").decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line.startswith("["):
            section = line
            continue
        if section == "[FIRs]" and line and not line.startswith(";"):
            parts = line.split("|")
            if len(parts) >= 4:
                names.setdefault(parts[3] or parts[0], parts[1])

    boundaries = json.loads(fetch(VATSPY + "Boundaries.geojson"))
    lines, labels = [], []
    for feat in boundaries["features"]:
        props = feat.get("properties", {})
        ident = props.get("id", "")
        if "-" in ident:
            continue  # controller sub-sectors (EDGG-N…); mPilot only draws whole FIRs
        geom = feat["geometry"]
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        rings = [rnd(ring) for poly in polys for ring in poly]
        lines.append({
            "type": "Feature",
            "properties": {"id": ident, "oceanic": str(props.get("oceanic", "0")) == "1"},
            "geometry": {"type": "MultiLineString", "coordinates": rings},
        })
        icao = ident
        # "Dublin ACC (Up to FL245) - Dublin" -> "Dublin ACC", like Lido's "Shanwick OAC EGGX".
        name = re.sub(r"\s*\(.*?\)", "", names.get(ident) or "").split(" - ")[0].strip()
        lat, lon = props.get("label_lat"), props.get("label_lon")
        if lat is not None and lon is not None:
            label = f"{name} {icao}".strip() if name and name.upper() != icao else icao
            labels.append({
                "type": "Feature",
                "properties": {"label": label},
                "geometry": {"type": "Point", "coordinates": [round(float(lon), 3), round(float(lat), 3)]},
            })
    write("firs.geojson", lines)
    write("fir-labels.geojson", labels)


def build_country_labels() -> None:
    countries = json.loads(fetch(NE + "ne_110m_admin_0_countries.geojson"))
    feats = []
    for f in countries["features"]:
        p = f["properties"]
        name = (p.get("NAME_EN") or p.get("NAME") or "").upper()
        x, y = p.get("LABEL_X"), p.get("LABEL_Y")
        if name and x is not None and y is not None:
            feats.append({
                "type": "Feature",
                "properties": {"name": name, "rank": p.get("LABELRANK", 5)},
                "geometry": {"type": "Point", "coordinates": [round(x, 2), round(y, 2)]},
            })
    write("country-labels.geojson", feats)


def build_airports() -> None:
    rows = csv.DictReader(io.StringIO(fetch(OURAIRPORTS).decode("utf-8")))
    feats = []
    for r in rows:
        if r["type"] not in ("large_airport", "medium_airport"):
            continue
        icao = r.get("icao_code") or r.get("gps_code") or r["ident"]
        if len(icao) != 4 or not icao.isalpha():
            continue
        # Medium airports only if they have scheduled service, to keep the map Lido-like.
        if r["type"] == "medium_airport" and r.get("scheduled_service") != "yes":
            continue
        feats.append({
            "type": "Feature",
            "properties": {"icao": icao.upper(), "rank": 1 if r["type"] == "large_airport" else 2,
                           "name": r["name"], "city": r.get("municipality") or "", "iata": r.get("iata_code") or "",
                           "elev": int(float(r["elevation_ft"])) if r.get("elevation_ft") else None},
            "geometry": {"type": "Point", "coordinates": [round(float(r["longitude_deg"]), 4), round(float(r["latitude_deg"]), 4)]},
        })
    write("airports.geojson", feats)


def build_navaids() -> None:
    rows = csv.DictReader(io.StringIO(fetch(OURAIRPORTS_NAVAIDS).decode("utf-8")))
    feats = []
    for r in rows:
        t = r["type"]
        kind = "ndb" if t.startswith("NDB") else "dme" if t in ("DME", "TACAN") else "vor"
        khz = float(r["frequency_khz"]) if r["frequency_khz"] else 0
        # VORs/DMEs are tuned in MHz, NDBs in kHz.
        freq = f"{khz / 1000:.2f}" if kind != "ndb" and khz else (f"{khz:g}" if khz else "")
        props = {"id": r["ident"], "name": r["name"].title(), "type": t, "kind": kind, "freq": freq,
                 "ch": r.get("dme_channel") or "", "elev": int(float(r["elevation_ft"])) if r.get("elevation_ft") else None,
                 "var": round(float(r["magnetic_variation_deg"]), 1) if r.get("magnetic_variation_deg") else None,
                 "apt": r.get("associated_airport") or "", "cc": r.get("iso_country") or ""}
        feats.append({"type": "Feature", "properties": props,
                      "geometry": {"type": "Point", "coordinates": [round(float(r["longitude_deg"]), 5), round(float(r["latitude_deg"]), 5)]}})
    write("navaids.geojson", feats)


def vatspy_sections() -> dict:
    sections, current = {}, None
    for line in fetch(VATSPY + "VATSpy.dat").decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("["):
            current = line.strip("[]")
            sections[current] = []
        elif current:
            sections[current].append(line.split("|"))
    return sections


def build_vatsim() -> None:
    sec = vatspy_sections()

    # Callsign prefix (callsign without _CTR/_FSS) -> boundary id, e.g. EDWW_ALR -> EDWW-ALR, EGTT -> EGTT.
    fir, fir_names = {}, {}
    for parts in sec.get("FIRs", []):
        if len(parts) < 4:
            continue
        icao, name, prefix, boundary = parts[0], parts[1], parts[2], parts[3] or parts[0]
        fir.setdefault(prefix or icao, boundary)
        fir.setdefault(icao, boundary)
        fir_names.setdefault(boundary, re.sub(r"\s*\(.*?\)", "", name).split(" - ")[0].strip())
    uir = {p[0]: p[2].split(",") for p in sec.get("UIRs", []) if len(p) >= 3}

    # Airports by ICAO and by IATA/FAA LID (US controllers log on as DFW_TWR).
    airports = {}
    for p in sec.get("Airports", []):
        if len(p) < 7:
            continue
        icao, name, lat, lon, lid, pseudo = p[0], p[1], float(p[2]), float(p[3]), p[4], p[6] == "1"
        entry = [round(lat, 4), round(lon, 4), name, icao]
        if not pseudo or icao not in airports:
            airports[icao] = entry
        if lid and (lid not in airports or not pseudo):
            airports.setdefault(lid, entry)

    boundaries = json.loads(fetch(VATSPY + "Boundaries.geojson"))
    sectors = [{
        "type": "Feature",
        # lx/ly: where VATSpy puts the sector's name label
        "properties": {"id": f["properties"]["id"],
                       "lx": round(float(f["properties"].get("label_lon") or 0), 3),
                       "ly": round(float(f["properties"].get("label_lat") or 0), 3)},
        "geometry": {"type": f["geometry"]["type"], "coordinates": rnd(f["geometry"]["coordinates"])},
    } for f in boundaries["features"]]
    write("vatsim-sectors.geojson", sectors)

    tracon_geo = json.loads(fetch(TRACONS))
    tracons, tracon_prefix = [], {}
    for i, f in enumerate(tracon_geo["features"]):
        props = f["properties"]
        tid = f"{props.get('id', '')}#{i}"
        tracons.append({
            "type": "Feature",
            "properties": {"id": tid, "name": props.get("name", "")},
            "geometry": {"type": f["geometry"]["type"], "coordinates": rnd(f["geometry"]["coordinates"])},
        })
        for prefix in props.get("prefix", []):
            tracon_prefix.setdefault(prefix, []).append(tid)
    write("vatsim-tracons.geojson", tracons)

    index = {"fir": fir, "firNames": fir_names, "uir": uir, "tracon": tracon_prefix, "airports": airports}
    path = os.path.join(OUT, "vatsim-index.json")
    with open(path, "w") as f:
        json.dump(index, f, separators=(",", ":"))
    print(f"vatsim-index.json: {len(fir)} FIR prefixes, {len(tracon_prefix)} TRACON prefixes, {len(airports)} airports, "
          f"{os.path.getsize(path) // 1024} KB")


VATGLASSES = "https://codeload.github.com/lennycolton/vatglasses-data/tar.gz/refs/heads/main"


def dms(value: str, deg_digits: int) -> float:
    """VATGlasses coordinates: "-ddmmss[.s]" (lat) / "-dddmmss[.s]" (lon); plain decimals are passed through."""
    v = str(value).strip()
    sign = -1 if v.startswith("-") else 1
    v = v.lstrip("+-")
    whole, _, frac = v.partition(".")
    if len(whole) in (deg_digits + 4,):  # DMS
        d, m, sec = int(whole[:deg_digits]), int(whole[deg_digits:deg_digits + 2]), float(whole[deg_digits + 2:] + ("." + frac if frac else ""))
        return sign * (d + m / 60 + sec / 3600)
    return sign * float(v)


def build_vatglasses() -> None:
    import tarfile
    archive = tarfile.open(fileobj=io.BytesIO(fetch(VATGLASSES)), mode="r:gz")
    positions, airspace = {}, []
    for member in archive.getmembers():
        parts = member.name.split("/")
        if len(parts) != 3 or parts[1] != "data" or not parts[2].endswith(".json"):
            continue
        stem = parts[2][:-5]
        try:
            data = json.load(archive.extractfile(member))
        except Exception as e:  # a broken data set shouldn't break the build
            print(f"  skipping {stem}: {e}")
            continue
        ref = lambda pid: pid if "/" in pid else f"{stem}/{pid}"
        for pid, p in (data.get("positions") or {}).items():
            colours = [{"online": [ref(o) for o in c.get("online", [])], "hex": c.get("hex", "#4A7A2E")}
                       for c in p.get("colours", [])]
            positions[ref(pid)] = {"pre": p.get("pre", []), "type": p.get("type", ""), "freq": p.get("frequency"),
                                   "name": p.get("callsign", ""), "colours": colours}
        for a in data.get("airspace") or []:
            blocks = []
            for sec in a.get("sectors", []):
                if sec.get("runways"):  # runway-dependent variants: skip, we don't know the active runway
                    continue
                try:
                    pts = [[round(dms(p[1], 3), 4), round(dms(p[0], 2), 4)] for p in sec["points"]]
                except Exception:
                    continue
                if len(pts) >= 3:
                    blocks.append({"min": sec.get("min"), "max": sec.get("max"), "pts": pts})
            if blocks and a.get("owner"):
                airspace.append({"id": a.get("id", ""), "owner": [ref(o) for o in a["owner"]], "blocks": blocks})
    path = os.path.join(OUT, "vatglasses.json")
    with open(path, "w") as f:
        json.dump({"positions": positions, "airspace": airspace}, f, separators=(",", ":"))
    print(f"vatglasses.json: {len(positions)} positions, {len(airspace)} airspaces, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build_firs()
    build_country_labels()
    build_airports()
    build_navaids()
    build_vatsim()
    build_vatglasses()
