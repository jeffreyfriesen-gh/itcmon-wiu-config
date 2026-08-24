# Observed ITCM base stations

This directory records base stations for which a valid coordinate-bearing
ITCM application `0x02` beacon has been preserved. Coordinates are the
transmitter coordinates decoded from the beacon payload; they are not the
truck receiver's GPS position.

The machine-readable inventory is available as
[`base-stations.json`](base-stations.json) and
[`base-stations.csv`](base-stations.csv).

## Inventory

| Radio ID | Railroad | Railroad status | Description | Description status | Latitude | Longitude | Map |
|---|---|---|---|---|---:|---:|---|
| `1856C4` | BNSF | Confirmed | North Glenwood, IA | Confirmed | `41.096953` | `-95.760575` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.096953,-95.760575) |
| `1856D8` | BNSF | Confirmed | Ashland, NE | Confirmed | `41.029347` | `-96.350377` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.029347,-96.350377) |
| `1857C5` | BNSF | Confirmed | Lincoln, NE | Confirmed | `40.861978` | `-96.626145` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.861978,-96.626145) |
| `1857C6` | BNSF | Confirmed | Red Oak, IA | Confirmed | `41.004575` | `-95.234952` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.004575,-95.234952) |
| `18582F` | BNSF | Confirmed | East Glenwood, IA | Confirmed | `41.049087` | `-95.670603` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.049087,-95.670603) |
| `185896` | BNSF | Confirmed | Fremont, NE | Confirmed | `41.428033` | `-96.495990` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.428033,-96.495990) |
| `18589E` | BNSF | Confirmed | Milford, NE | Confirmed | `40.726347` | `-96.977002` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.726347,-96.977002) |
| `1858C0` | BNSF | Operator supplied; radio-family consistent | Fairmont, NE | Operator supplied | `40.641480` | `-97.503163` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.641480,-97.503163) |
| `185BE4` | BNSF | Operator supplied; radio-family consistent | York, NE | Operator supplied | `40.828248` | `-97.554787` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.828248,-97.554787) |
| `4800AF` | UP | Confirmed | Gretna, NE | Confirmed | `41.175370` | `-96.257730` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.175370,-96.257730) |
| `4800D5` | UP | Confirmed | Bennington, NE | Confirmed | `41.367783` | `-96.233933` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.367783,-96.233933) |
| `4800D7` | UP | Confirmed | Blair, NE | Confirmed | `41.509610` | `-96.174502` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.509610,-96.174502) |
| `4801FB` | UP | Operator supplied; radio-family consistent | Marysville, KS | Operator supplied | `39.784330` | `-96.706040` | [Google Maps](https://www.google.com/maps/search/?api=1&query=39.784330,-96.706040) |
| `48035F` | UP | Operator supplied; radio-family consistent | Weeping Water, NE | Operator supplied | `40.868880` | `-96.140510` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.868880,-96.140510) |

## Evidence and confidence

- `Confirmed` means the railroad and description already exist in the reviewed
  radio-identity registry.
- `Operator supplied` means the description was supplied on 2026-08-24. The
  railroad is consistent with the previously observed `18xxxx` BNSF and
  `48xxxx` UP radio families, but has not yet been independently tied to a
  reviewed registry record.
- `coordinate_status: observed_base_beacon` means the latitude and longitude
  came from a valid, nonzero coordinate-bearing beacon for that radio ID.
- `185896` and `1857C6` are preserved historical observations outside the
  dashboard's current seven-day retained inventory. The other 12 appeared in
  the retained inventory observed at `2026-08-23T08:58:06.701Z`.
- Invalid `000000`/`0,0` beacons and coordinate-less base-like radios are
  excluded.

The originally supplied `1856C4` row duplicated Gretna station `4800AF`'s
coordinates. This inventory uses the observed North Glenwood coordinates
`41.096953, -95.760575`.

The supplied constant values `2` and `411` had no column headings and are not
stored because their semantics cannot be established from the submitted table.
