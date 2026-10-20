# mPilot design reference (for SimPilot EFB)

Sources: the six iPad screenshots on the App Store listing for Lido mPilot 7.x
(Weather, AMM, Themes, Navigation_General, Integrations, Avionics). They're
studied here so the layout and behaviour can be matched. Lido/Lufthansa names
and logos are **not** reused.

## Global shell (landscape iPad)

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ (≡) Cycle: 2602: 19 Feb - 18 Mar   [📅+00:00  ?  zᶻ  文A  v1.0.0]  [A350 ✈] (🔍) (✓)│  top bar, 52pt
│     Route not saved                                                            │
├──────────────┬────────────────────────────────────────────────────────────────┤
│ Flight Folder│                                                [NAV|CMPY|WX]   │
│ [Edit Flight][…]                                              [FL380]         │
│ ◎ EDDF   ›   │              map / chart content                [FL310]         │
│ ↑ Route  ›   │                                                [FL250]         │
│ ◎ FAOR   ›   │                                                                │
│ ◎ LSZH   ›   │                                                                │
│ [Add Alternate]                                                               │
│ 🗎 Documents › │ (compass)                                                     │
│ 📍 Route Notes›│ 500 km ───                                          [ ➤ ]     │
├──────────────┴────────────────────────────────────────────────────────────────┤
│ [Low|High]          [⛰  ⋯  ⓘ  TT  ▭]                       [🗎  🗺  ✎]           │  bottom toolbar, 50pt
└───────────────────────────────────────────────────────────────────────────────┘
```

### Top bar
- Background `#22252B` (dark) / `#F2F2F4` (light). Controls are pills (`#2E3138`, radius 18).
- Left: round hamburger button (opens the side menu: Flight Folder / settings).
  Title is two lines: **bold** `Cycle: 2602: 19 Feb - 18 Mar` (AIRAC cycle + validity); the subtitle in grey 12pt shows the route state (`Route not saved` / `EHAM-MPTO`).
  On the AMM the title becomes `KSFO-AMM: 19 Feb - 18 Mar` followed by a `…` pill.
- Centre pill group: `[calendar-UTC icon] +00:00` (time offset for the weather time slider), `?` help, `zᶻ` night-mode toggle
  (crossed-out sleep icon), `文A` label-language/declutter, then the version string in 9pt grey.
- Right: pill with the aircraft type (`AIRBUS A350`) + aircraft icon (opens aircraft selection), round search
  button, and a round green ✓ (data-sync / connection status; it can carry a blue badge count; red/orange when stale).

### Flight Folder (left sidebar, ~310pt wide, `#2B2E34`)
- Centred title `Flight Folder`.
- Row of buttons: wide `Edit Flight` (grey pill `#3A3D44`) + small `…`.
- List rows (64pt): airport icon (Lido "gear" airport symbol) coloured by role —
  **green** origin, **orange** destination, **pink/magenta** alternates; bold ICAO (17pt), grey subtitle
  `Frankfurt - FRA` (city - IATA); chevron `›` on the right. The route row uses a route icon, title `Route`, and the distance (`4787 NM`) as its subtitle.
- `Add Alternate` full-width grey pill.
- `Documents` (doc icon) and `Route Notes` (pin icon) rows.
- Hairline separators `#3A3D44`.

### Map overlays (enroute)
- Top-right **layer box**: a rounded translucent dark panel with three cells: `NAV` (stack icon, count `4`),
  `CMPY` (stack icon, count `9`), `WX` (count). Small caps labels on top (8pt).
- Below it, the **FL selector**: a box listing three levels (`FL380 / FL310 / FL250`). It selects the weather level.
- Bottom-left: a small compass rose circle (rotates with the map; shows the magvar on the AMM, e.g. `14° E`) and a
  scale bar with two units (`500 km` above, `200 NM` below; on the AMM `200 m` / `500 ft`).
- Bottom-right: a square **centre-on-ownship** button (navigation arrow). It turns blue when it's following.

### Bottom toolbar (enroute)
- Left: segmented `Low | High` (low/high enroute chart).
- Centre pill: vertical profile (mountain icon), declutter (dots), info `ⓘ`, text size `TT`, ruler/scale.
- Right pill: `Charts` (document), `Map` (map, **selected = blue round fill `#2F6FE4`**), `Annotate` (pen).

### Bottom toolbar (AMM)
- Left: `← | AGC →` (previous/next ground chart).
- Centre: label toggle, `TT`, `ⓘ`, route (diamond), runway, pen, split view.
- Right: document, map, ownship-follow (blue when active).

## Enroute map styling (dark theme)
| element | style |
|---|---|
| background / sea | `#162231` deep navy; land slightly lighter `#1E2A38` with dark-grey hillshade |
| FIR/UIR/ACC boundaries | green `#3DAA55` 1.5px with green italic labels (`Shanwick OAC EGGX`) |
| ADIZ / restricted / danger (P, R, D, TRA) | magenta `#C2338A` lines; restricted areas get a semi-transparent brownish-red fill hatch `#7A3B3B` |
| grid MORA | large red italic numbers `#D23A3A` (e.g. `214` with the last digit subscript) |
| airports | blue "gear" symbol `#3D8BFF` with blue bold ICAO label; airports without charts are grey gear `#8A8F98` |
| VOR/DME | yellow-bordered dark label boxes `D 117.1 VSA` (`#F2C230` border, `#1B1E23` fill, white text) |
| route | amber/gold line `#E8B04A` 3px; waypoints = white-outline triangles with bold white labels on a dark halo |
| airways | grey `#6E7681` thin lines with route designator labels (`A201`) and distances |
| ownship | blue `#3D8BFF` airplane triangle with a translucent blue halo circle `rgba(61,139,255,0.35)` (r ≈ 36pt) |
| graticule | faint grey lines with labels `E20°`, `S20°`, `N35°` |
| weather | radar: green/yellow/red/magenta pixels; SIGMETs: purple outlined polygons |

**Light theme:** white background, beige/brown hypsometric terrain, the same magenta and green boundaries, red MORA.

## Vertical profile
A bottom sheet (~220pt) over the map, translucent `#2A2D33E6`. Y-axis FL100…FL500 labels on the left; the route profile
is a gold line with triangle waypoints and labels rotated 60°; terrain is filled dark; weather is coloured bars (convection green, turbulence/icing purple/blue). The ownship is a blue marker on the line.

## Airport Moving Map (AMM)
| element | style |
|---|---|
| background | `#3A3F47` grass/terrain; water `#1C2A3A`; buildings/terminals black `#111` with white caps labels |
| pavement (aprons/taxiways) | `#4A4F58` |
| taxiway centrelines | yellow `#E2B73B` 1px; taxiway idents white bold 13pt (`A`, `M1`, `B`) |
| holding points / stop bars | thick yellow bars `#F5C518` across the taxiway |
| runways | near-black `#15171A` with white markings (threshold piano keys, centreline dashes) |
| runway ends | blue circle badge `#2F7BE5` with rotated ident (`01R`); the active/occupied runway gets a green badge `#2FA84F` |
| stands | salmon outlined triangles `#E07A5F` pointing to the stand, label `B12` |
| hot spots | magenta rounded squares `#D13C8A` with a number |
| status banner | top-centre dark-blue box `#1F3550` with white caps text `ON RWY 01L-19R` |
| ownship | blue airplane in a blue translucent circle |

## Interaction notes
- The map rotates and pans; the ownship button re-centres and re-enables follow.
- Tapping an airport in the Flight Folder opens that airport's charts (the Charts module), filtered by runway.
- The day/night toggle switches the whole UI theme (charts invert to their night version).
- Split view: the AMM on one side, the selected ground chart on the other.

## Typography
SF Pro (system): title 17pt semibold, rows 17/13pt, toolbar 15pt, map labels condensed bold 11–13pt.
