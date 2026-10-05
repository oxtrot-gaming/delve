# Storage report — everything a stockpile can hold

Companion to the shelving work (Item 38): what can sit in a stockpile
cell, how heavy it is, and how much room it takes — the numbers needed
to decide how shelves should be *better* than bare floor.

Volumes come from `scripts/colony/drop_item.gd` (form constants),
densities from `scripts/world/block_registry.gd` (`RESOURCE_DENSITY`,
kg/L). Mass = volume × density; a full cubic metre is 1,000 L.

## Cell capacities

| Storage            | Capacity      | Notes                                        |
|--------------------|---------------|----------------------------------------------|
| Bare floor pile    | 1,000,000 cm³ | 1 m³ — `DropItem.BLOCK_CM3`                   |
| Shelf cell         | 2,000,000 cm³ | `Colony.SHELF_PILE_CM3` — 2× floor            |

Loose goods pour to fill whatever room exists; discrete items pack to
`floor(capacity / item_volume)` — so items just over half a cell pack
worst (a log is 500 L: two per cell, nothing else fits beside them).

## Excavated earth

Loose only — pours; kg/cell is just capacity × density.

| Resource | Density | Mass per floor cell | Mass per shelf cell |
|----------|---------|--------------------:|--------------------:|
| Soil     | 1.6 kg/L | 1,600 kg | 3,200 kg |
| Clay     | 1.8 kg/L | 1,800 kg | 3,600 kg |

## Rock and ore

Mine drops are boulders (100 L) and cobbles (10 L); the crush bills can
break them down further into loose fill, which packs perfectly.

| Resource     | Density | Boulder | Cobble | Loose /m³ |
|--------------|---------|--------:|-------:|----------:|
| Stone        | 2.6 kg/L | 260 kg | 26 kg | 2,600 kg |
| Coal         | 1.4 kg/L | 140 kg | 14 kg | 1,400 kg |
| Hematite     | 4.2 kg/L | 420 kg | 42 kg | 4,200 kg |
| Malachite    | 3.9 kg/L | 390 kg | 39 kg | 3,900 kg |
| Cassiterite  | 5.0 kg/L | 500 kg | 50 kg | 5,000 kg |
| Native gold  | 6.0 kg/L | 600 kg | 60 kg | 6,000 kg |

Per cell: 10 boulders / 100 cobbles (floor), 20 / 200 (shelf). Discrete
forms already pack by volume, so shelving these gains density only, not
efficiency — a floor cell of hematite boulders is already 4,200 kg.

## Smelted metal and metal goods

Smelt output is loose granules; metalwork adds sheets (50 L), wire
(2.5 L) and components (5 L).

| Resource | Density | Loose /m³ | Sheet (50 L) | Wire (2.5 L) | Component (5 L) |
|----------|---------|----------:|-------------:|-------------:|----------------:|
| Iron     | 4.0 kg/L | 4,000 kg | 200 kg | 10.0 kg | 20 kg |
| Copper   | 4.2 kg/L | 4,200 kg | 210 kg | 10.5 kg | 21 kg |
| Tin      | 3.8 kg/L | 3,800 kg | 190 kg |  9.5 kg | 19 kg |
| Gold     | 4.0 kg/L | 4,000 kg | 200 kg | 10.0 kg | 20 kg |

Per cell: 20 sheets / 400 wire / 200 components (floor), 40 / 800 /
400 (shelf). These are the densest storable goods in the game — a
shelf cell of copper sheet is 8,400 kg sitting on one voxel.

## Wood and plant bulk

| Resource | Density | Form | Item volume | Item mass | Per floor cell | Per shelf cell |
|----------|---------|------|------------:|----------:|---------------:|---------------:|
| Wood     | 0.6 kg/L | Log   | 500 L | 300 kg |   2 → 600 kg |   4 → 1,200 kg |
| Wood     | 0.6 kg/L | Plank | 100 L |  60 kg |  10 → 600 kg |  20 → 1,200 kg |
| Wood     | 0.6 kg/L | Sheet |  50 L |  30 kg |  20 → 600 kg |  40 → 1,200 kg |
| Wood     | 0.6 kg/L | Loose |   —   |   —    |      600 kg  |      1,200 kg  |
| Branch   | 0.45 kg/L | Loose |   —   |   —    |      450 kg  |        900 kg  |
| Leaf     | 0.15 kg/L | Loose |   —   |   —    |      150 kg  |        300 kg  |
| Charcoal | 0.4 kg/L | Loose |   —   |   —    |      400 kg  |        800 kg  |

Logs are the worst packers among the common goods — two to a cell
because the 500 L form can't share a cell with anything else (a plank
or sheet alongside would exceed the metre).

## Agriculture and food

| Resource | Density | Form  | Item volume | Item mass | Per floor cell | Per shelf cell |
|----------|---------|-------|------------:|----------:|---------------:|---------------:|
| Berries  | 0.9 kg/L | Fruit | 2.5 L | 2.25 kg | 400 →   900 kg | 800 → 1,800 kg |
| Acorns   | 0.9 kg/L | Fruit | 2.5 L | 2.25 kg | 400 →   900 kg | 800 → 1,800 kg |
| Seeds    | 0.75 kg/L | Seed | 1.0 L | 0.75 kg | 1,000 → 750 kg | 2,000 → 1,500 kg |
| Grain    | 0.8 kg/L | Loose |   —   |    —    |         800 kg |        1,600 kg |
| Raw cotton | 0.2 kg/L | Loose |  —   |    —    |         200 kg |          400 kg |
| Compost  | 1.0 kg/L | Loose |   —   |    —    |       1,000 kg |        2,000 kg |
| Meals    | 1.0 kg/L | Meal  |  10 L |   10 kg | 100 → 1,000 kg | 200 → 2,000 kg |
| Meat     | 1.05 kg/L | Loose |  —   |    —    |       1,050 kg |        2,100 kg |

Raw cotton is the lightest bulk in the game — a full floor pile is only
200 kg. Seeds are the reverse edge case: tiny items, near-perfect
packing already.

## Animal products

Butcher output (meat, leather, bone) and hunt byproducts are loose;
corpses are species-sized discrete items (`Species.corpse_cm3`).

| Resource | Density | Form   | Notes                                    |
|----------|---------|--------|------------------------------------------|
| Corpse   | 1.05 kg/L | Corpse | Species-dependent volume — a rabbit and a deer differ hugely |
| Meat     | 1.05 kg/L | Loose  | 1,050 kg per floor cell                  |
| Leather  | 0.95 kg/L | Loose  |   950 kg per floor cell                  |
| Bone     | 1.9 kg/L  | Loose  | 1,900 kg per floor cell                  |
| Scraps   | 0.9 kg/L  | Loose  |   900 kg per floor cell                  |
| Antler   | 1.8 kg/L  | Loose  | 1,800 kg per floor cell                  |
| Tusk     | 1.9 kg/L  | Loose  | 1,900 kg per floor cell                  |

## Textiles, gear and furniture kits

| Resource | Density | Form    | Item volume | Item mass | Per floor cell | Per shelf cell |
|----------|---------|---------|------------:|----------:|---------------:|---------------:|
| Cotton cloth | 0.35 kg/L | Loose |    —   |    —    |        350 kg |          700 kg |
| Cloth garment | 0.35 kg/L | Garment | 6 L | 2.1 kg | 166 → 350 kg | 333 → 700 kg |
| Leather garment | 0.95 kg/L | Garment | 6 L | 5.7 kg | 166 → 950 kg | 333 → 1,900 kg |
| Tool | material-dependent | Tool | 8 L | wood 4.8 / iron 32 kg | 125 | 250 |
| Bed kit | 0.6 kg/L (wood) | Bed | 400 L | 240 kg |   2 → 480 kg | 5 → 1,200 kg |

The bed kit is the other bad packer — 400 L means a floor cell holds
two with 200 L wasted, while a shelf cell holds five with none.

## Medicine

| Resource | Density | Form  | Notes                              |
|----------|---------|-------|------------------------------------|
| Heal-all | 0.3 kg/L | Loose | 300 kg per floor cell — dried herbs |

## What the numbers suggest

- **Density-wise** the heaviest storage is metal sheet (8.4 t/shelf
  cell) and ore loose fill (6 t/cell) — a compact vault story.
- **Packing-wise** the wins for shelving aren't density but *waste*:
  logs, bed kits and boulders leave dead volume in a floor cell because
  discrete forms can't share. If shelves should feel better than the
  floor for "certain classes of objects", the natural lever is a
  per-form packing factor rather than a flat capacity — e.g. shelving
  could let discrete items count at less than face volume (log 500 L →
  400 L shelved) since racks stack them tighter.
- **Loose goods** gain nothing but the flat 2× — soil, grain and cotton
  already pack perfectly, so bins/racks only matter as capacity.
- **Corpses** are the open question: species-sized, some likely over
  the floor cap already (a big carcass won't fit a 1 m³ cell and
  spills) — shelves sized for game would be a real feature, not a
  convenience.
