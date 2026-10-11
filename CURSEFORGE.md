# Provisions

**One button to eat, drink, potion, bandage — always with the best item in your bags.**

Provisions keeps a handful of general macros pointed at the right consumable. Loot new food, level up, run out of a stack: the macros update by themselves. Put them on your action bars once and forget about them.

## Macros
Open `/macro` → **General** tab and drag them onto your bars:

| Macro | Uses |
|---|---|
| **EatDrink** | best food and drink in one press (or split into **Eat** / **Drink**) |
| **HealPot** | best healing potion |
| **ManaPot** | best mana potion |
| **Bandage** | best bandage your First Aid skill allows |
| **Healthstone** | best healthstone |

- Strongest first by default, or **weakest first** per group to use up old stock.
- Conjured food and drink first (they vanish on logout anyway).
- Skips buff food so you don't waste your Well Fed stuff on regen.
- Characters without mana never get drinks.

## Item bar
A small bar shows what each macro would use and how many you have left.
- Click to use (optional), right-click to pick a specific item for that slot.
- Choose which item types appear, icon size and grow direction.
- Lock it, or make it click-through. **Alt + click** unlocks it any time.

## Settings
Minimap button or `/prov`. Options and the bar layout are shared by all your characters; item order, bar items and picks are per character.

## Commands
- `/prov` — settings window
- `/prov info` — what each macro currently uses
- `/prov order <food|potions|bandage|healthstone> <high|low>`
- `/prov resetbar` — move the bar back to the centre
- `/prov minimap` — show/hide the minimap button
- `/prov reset` — factory reset

Lightweight: scans only when your bags change, no combat-log parsing, nothing runs in combat that could get blocked.
