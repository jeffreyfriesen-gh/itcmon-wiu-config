# Observed ITCM base stations

This directory records base stations for which a valid coordinate-bearing
ITCM application `0x02` beacon has been preserved. Coordinates are the
transmitter coordinates decoded from the beacon payload; they are not the
truck receiver's GPS position.

The machine-readable inventory is available as
[`base-stations.json`](base-stations.json) and
[`base-stations.csv`](base-stations.csv).

## Inventory

| Radio ID | Railroad | Description | Latitude | Longitude | Map |
|---|---|---|---:|---:|---|
| `1856C4` | BNSF | North Glenwood, IA | `41.096953` | `-95.760575` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.096953,-95.760575) |
| `1856D8` | BNSF | Ashland, NE | `41.029347` | `-96.350377` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.029347,-96.350377) |
| `1857C5` | BNSF | Lincoln, NE | `40.861978` | `-96.626145` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.861978,-96.626145) |
| `1857C6` | BNSF | Red Oak, IA | `41.004575` | `-95.234952` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.004575,-95.234952) |
| `18582F` | BNSF | East Glenwood, IA | `41.049087` | `-95.670603` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.049087,-95.670603) |
| `185896` | BNSF | Fremont, NE | `41.428033` | `-96.495990` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.428033,-96.495990) |
| `18589E` | BNSF | Milford, NE | `40.726347` | `-96.977002` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.726347,-96.977002) |
| `1858C0` | BNSF | Fairmont, NE | `40.641480` | `-97.503163` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.641480,-97.503163) |
| `185BE4` | BNSF | York, NE | `40.828248` | `-97.554787` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.828248,-97.554787) |
| `4800AF` | UP | Gretna, NE | `41.175370` | `-96.257730` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.175370,-96.257730) |
| `4800D5` | UP | Bennington, NE | `41.367783` | `-96.233933` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.367783,-96.233933) |
| `4800D7` | UP | Blair, NE | `41.509610` | `-96.174502` | [Google Maps](https://www.google.com/maps/search/?api=1&query=41.509610,-96.174502) |
| `4801FB` | UP | Marysville, KS | `39.784330` | `-96.706040` | [Google Maps](https://www.google.com/maps/search/?api=1&query=39.784330,-96.706040) |
| `48035F` | UP | Weeping Water, NE | `40.868880` | `-96.140510` | [Google Maps](https://www.google.com/maps/search/?api=1&query=40.868880,-96.140510) |

All 14 entries are observed base stations with valid, nonzero coordinates
decoded from their own base-beacon payloads. Invalid `000000`/`0,0` beacons and
coordinate-less base-like radios are excluded.

The originally supplied `1856C4` row duplicated Gretna station `4800AF`'s
coordinates. This inventory uses the observed North Glenwood coordinates
`41.096953, -95.760575`.

The supplied constant values `2` and `411` had no column headings and are not
stored because their semantics cannot be established from the submitted table.
