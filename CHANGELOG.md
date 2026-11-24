# Provisions

## v1.7
- New: the raid bar. A bar for your own raid buffs (flasks, elixirs, buff food, juju, world buffs, scrolls, weapon oils and stones), a separate list for each character.
- New: the raid stims bar. A second bar for short-use items you only need on certain fights (protection potions, Free Action, Stoneshield...). It works the same way and has its own position and settings.
- Drag an item from your bags onto a bar to add it, or type `/prov raid add` or `/prov stims add` and shift-click the item. Right-click an icon to move it, send it to the other bar, remove it, switch its glow on or off, or pick main or off hand.
- Left-click uses the item. Weapon oils, sharpening stones, weightstones and poisons go straight onto your main hand (or off hand).
- Items you've run out of stay on the bar, greyed out with 0, as a restock reminder.
- Glow: an icon pulses orange when you carry the item but its buff isn't on you (in raids), and gets a steady green frame while the buff is up, with the time left on the icon. Each bar can glow for both, missing only, active only, or not at all. The raid bar shows both by default, the stims bar only active stims.
- Which buff an item gives is read from the game, so this works in any client language. Items Provisions doesn't know yet are learned the first time you use them.
- Presets: load a ready-made list onto both bars, starting with Protection Paladin. Right-click the + on a bar, use the Presets row in the Raid bar tab, or type `/prov raid preset protpaladin`. You choose whether to add what's missing or replace your lists.
- New: Demonic Rune and Dark Rune on the main item bar and as a Rune macro (classes with mana only). Runes have their own row in the Item order tab.
- New: a Buff food button on the item bar and a BuffFood macro: your best Well Fed (Nutritious) dish, for its stat buff and WoW Forever's +5% experience from kills. Buff food has its own row in the Item order tab. The "Show on the bar" chips now sit in two rows.
- New Raid bar tab in the settings (`/prov`) with a page for each bar: show it always, only in raids, or hide it; glow; lock; grow direction. Icon size is shared with the item bar.
- Two small buttons at the end of the item bar show or hide the raid bar and the raid stims bar (Item bar tab, Behaviour page: Raid bar buttons on/off).
- `/prov raid list`, `/prov raid clear` (and the same for `stims`). `/prov resetbar` now moves all bars back to the centre.
- Fix: the settings window opens on the first click (it needed two).
- Fix: recipes are no longer taken for food. A cooking recipe shows the tooltip of the dish it teaches, so it could end up on the Buff food button or in the Eat macro.
- Runes are also recognised from their tooltip text, in case the game's item IDs differ from Provisions' table.

## v1.6
- Works on game clients in every language. Provisions now comes with a table of the game's food, drink, potions, bandages and healthstones (read from the game itself), so it no longer needs English tooltip text. An item that isn't in the table is still read from its tooltip, which only works on an English client.
- Right after logging in, the macros and the bar are ready at once instead of after the tooltips have loaded.

## v1.5.3
- Fixed: logging in or reloading during a fight with the clickable bar on gave "Interface action failed because of an AddOn" and a bar that didn't work until the fight ended. The bar now appears once the fight is over.
- Fixed: after a fresh login, item or spell data loading anywhere in the game (tooltips, vendors, the auction house, other addons) could make Provisions re-check your bags up to twice a second for the rest of the session. It now only re-checks when the item it's waiting for loads.
- Items Provisions has given up waiting for no longer ask the game for their data again on every bag check (most noticeable on non-English game clients).

## v1.5.2
- Fixed: the bar and macros went empty after a reload on a flight path (or while stunned, feared etc.). They now keep their items, and refresh when you land.
- Items you could use once stay on the bar for the session, so a temporary "can't use that now" from the game no longer empties it.

## v1.5.1
- Fixed: food (or other items) sometimes missing from the bar and macros after logging in or switching characters, until your bags changed. Items whose tooltip text loads late are now picked up as soon as it arrives.
- Fixed: the bar and macros went empty while you were dead. They now keep showing what you'll use once you're back.
- New: `/prov debug` lists the consumables in your bags and how Provisions sees them.
- The first-login hint now points to the settings window (`/prov`, Item order tab) for dragging the buttons onto your bars.

## v1.5
- Options and the item bar (position, size, lock, click behaviour) are now shared by all your characters.
- Item order, which items the bar shows and right-click picks stay per character.
- `/prov reset` resets the shared settings plus this character's own.
