# Provisions

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
