-- Provisions: keeps five general macros pointed at the best usable items in your bags:
--   EatDrink  (macro) best food + drink in one press  -- or, with "Separate" in the settings:
--   Eat / Drink  two macros, one for food and one for drink
--   HealPot   best healing potion
--   ManaPot   best mana potion
--   Bandage   best bandage you have the First Aid skill for (normal game targeting)
--   Healthstone  best healthstone (own cooldown, separate from potions)
-- Order: strongest first by default; "/prov order potions low" uses the weakest first
-- (groups: food, potions, bandage, healthstone).
-- Drag them onto your bars from the settings window (/prov, Item order tab). They are shared between characters;
-- each character rewrites them for its own bags when it logs in.
-- Addons may not use items themselves, so we only rewrite the macro text (allowed out of combat).

local ADDON = ...
local MACRO_ICON = 134400 -- question mark; #showtooltip swaps in the item icon

local GetItemInfo = C_Item and C_Item.GetItemInfo or _G.GetItemInfo
local IsUsableItem = C_Item and C_Item.IsUsableItem or _G.IsUsableItem

-- Chat output: main chat tab plus a tab named "wsp" (if you have one)
local EXTRA_TAB = "wsp"
local function chatOut(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local msg = table.concat(parts, " ")
    local main = DEFAULT_CHAT_FRAME
    main:AddMessage(msg)
    local getInfo = FCF_GetChatWindowInfo or GetChatWindowInfo
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        local name = getInfo and getInfo(i)
        if (not name or name == "") and _G["ChatFrame" .. i .. "Tab"] then name = _G["ChatFrame" .. i .. "Tab"]:GetText() end
        if cf and cf ~= main and name and name:lower() == EXTRA_TAB then cf:AddMessage(msg) end
    end
end
local print = chatOut

local f = CreateFrame("Frame")
local pending = false
local lastPick = {}
local panelRefresh -- set once the settings panel exists
local barRefresh   -- set once the item bar code is loaded
local setBarGrow   -- set once the item bar code is loaded
local makeSlot     -- builds one bar icon (display or clickable)
local openFlyout   -- right-click list of all items of one type
local unlockBar    -- Alt + click on the bar unlocks it
local tooltipBesideFlyout -- places GameTooltip next to the open list instead of on top of it
local lastCands = {} -- [key] = { [itemID] = {id, v, conj} } every usable candidate from the last scan
local barChangeAllowed -- false while the clickable bar is locked by combat
local barErrorShown = false
local function safeBarRefresh() -- the bar must never break macro updates
    if not barRefresh then return end
    local ok, err = pcall(barRefresh)
    if not ok and not barErrorShown then
        barErrorShown = true
        print("|cff33ff99Provisions|r item bar error (macros still work): " .. tostring(err))
    end
end
local waitingForData, retries = false, 0
local retryPending = false -- at most one retry timer at a time
local settleStart = GetTime() -- reset on every loading screen; item data can be incomplete for a while
local tip -- fallback scanning tooltip

-- Drinks are only used by characters that have a mana bar (checked live, so any class/race
-- combination works). Warriors and rogues never have one.
local NO_MANA = { WARRIOR = true, ROGUE = true }
local function usesMana()
    local _, class = UnitClass("player")
    if NO_MANA[class] then return false end
    local manaType = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
    return (UnitPowerMax("player", manaType) or 0) > 0
end

local function bagSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) end
    return GetContainerNumSlots(bag)
end

local function bagItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount end
        return
    end
    local _, count, _, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
    return id or (link and tonumber(link:match("item:(%d+)"))), count
end

local function tooltipLines(bag, slot)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetBagItem then
        local data = C_TooltipInfo.GetBagItem(bag, slot)
        if data and data.lines then
            for _, l in ipairs(data.lines) do
                if l.leftText then lines[#lines + 1] = l.leftText end
            end
            return lines
        end
    end
    if not tip then
        tip = CreateFrame("GameTooltip", "ProvisionsScanTip", nil, "GameTooltipTemplate")
        tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    tip:ClearLines()
    tip:SetBagItem(bag, slot)
    for i = 1, tip:NumLines() do
        local fs = _G["ProvisionsScanTipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t then lines[#lines + 1] = t end
    end
    return lines
end

local function num(s) return s and tonumber((s:gsub(",", ""))) end

-- Amounts restored on one tooltip line ("70 to 90 health" counts as 90)
local function amounts(line)
    local h = num(line:match("([%d,]+) health"))
    local m = num(line:match("([%d,]+) mana"))
    if line:find("mana and health") then h = m end
    if line:find("health and mana") then m = h end
    return h or 0, m or 0
end

-- First Aid skill rank (0 if not learned / unknown)
local function firstAidRank()
    if not GetNumSkillLines then return nil end
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        if not isHeader and name == "First Aid" then return rank or 0 end
    end
    return 0
end

-- Sorts an item into a category. Returns kind ("food"/"potion"/"bandage"), health, mana;
-- or nil if not relevant; third value true if item data isn't loaded yet.
-- Reads an item's tooltip once and returns what it is (tooltips of an item never change).
-- Returns an info table, false if irrelevant, or "pending" if the game hasn't loaded the text yet.
local function parseItem(bag, slot, itemID, itemName, classID, subClassID)
    local lines = tooltipLines(bag, slot)
    local consumable = (classID == 0)
    -- Right after starting the game, tooltips can come back without their "Use:" text
    -- for a few seconds. Treat that as "not loaded yet" instead of "not food".
    local hasUse, seated = false, false
    for _, line in ipairs(lines) do
        if line:find("^Use:") then hasUse = true end
        if line:find("remain seated while") then seated = true end -- "...while eating/drinking"
    end
    if not hasUse then
        if consumable or #lines <= 1 then return "pending" end
        -- Not a consumable and no "Use:" text. Ask the item data (not the tooltip) whether it
        -- has a use effect at all: if yes, the tooltip just isn't fully loaded yet (happens right
        -- after login), so wait. Raw fish is filed as a trade good but has an eat effect.
        local getSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
        local spellName, spellID = nil, nil
        if getSpell then spellName, spellID = getSpell(itemID) end
        if spellName or spellID then return "pending" end
        if GetTime() - settleStart < 30 then return "later" end -- just logged in: don't rule it out yet
        return false -- ordinary trade goods / gear: nothing to use
    end

    -- Food & drink: the game's Food & Drink category, or anything you must sit down to eat/drink
    -- (raw fish and some quest/crafting items are filed as trade goods but are still edible)
    if (consumable and subClassID == 5) or seated then
        local health, mana = 0, 0
        for _, line in ipairs(lines) do
            if line:find("^Use:") or line:find("[Rr]estores") then
                local h, m = amounts(line)
                if h > health then health = h end
                if m > mana then mana = m end
            end
        end
        if health == 0 and mana == 0 then return false end
        local conjured = itemName and itemName:find("^Conjured") ~= nil
        local buff = false -- "...you will become well fed and gain..."
        for _, line in ipairs(lines) do
            if line == "Conjured Item" then conjured = true end
            if line:lower():find("well fed") then buff = true end
        end
        return { kind = "food", health = health, mana = mana, conjured = conjured, buff = buff }
    end

    if not consumable then return false end -- potions, bandages, stones are always consumables

    -- Healthstones: "Use: Instantly restores 100 life." (checked before potions: separate cooldown)
    local isStone = itemName and itemName:find("Healthstone")
    local stone = 0
    for _, line in ipairs(lines) do
        local v = num(line:match("[Rr]estores ([%d,]+) life"))
        if v then isStone = true; stone = math.max(stone, v) end
        if isStone and stone == 0 then stone = amounts(line) end
    end
    if isStone then
        if stone == 0 then stone = 1 end
        return { kind = "stone", health = stone, mana = 0 }
    end

    -- Bandages: "Use: Heals 66 damage over 6 sec."
    local heal, skillNeeded
    for _, line in ipairs(lines) do
        local h = num(line:match("[Hh]eals ([%d,]+) damage"))
        if h then heal = h end
        local req = num(line:match("Requires First Aid %(([%d,]+)%)"))
        if req then skillNeeded = req end
    end
    if heal then return { kind = "bandage", health = heal, mana = 0, skillNeeded = skillNeeded } end

    -- Potions: instant "Use: Restores 70 to 90 health." (not over time, so no food/regen items)
    local health, mana = 0, 0
    for _, line in ipairs(lines) do
        if line:find("^Use:") and line:find("[Rr]estores") and not line:find("over [%d,]+ sec") then
            local h, m = amounts(line)
            if h > health then health = h end
            if m > mana then mana = m end
        end
    end
    if health == 0 and mana == 0 then return false end
    return { kind = "potion", health = health, mana = mana }
end

local infoCache = {}    -- [itemID] = info table, or false if not relevant
local pendingSince = {} -- [itemID] = when its data was first found incomplete
local gaveUp = {}       -- [itemID] = true: stopped the fast retries, still re-checked on every scan
local GIVE_UP_AFTER = 60  -- seconds of fast retries (every 2 s) before falling back to normal scans

local function notReady(itemID)
    local now = GetTime()
    pendingSince[itemID] = pendingSince[itemID] or now
    -- The item's "Use:" text comes from its spell, which can load late (or only when you hover
    -- the item). Ask for both; SPELL_TEXT_UPDATE / ITEM_DATA_LOAD_RESULT then trigger a rescan.
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    local getSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    local spellID = getSpell and select(2, getSpell(itemID))
    if spellID and C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, spellID) end
    if now - pendingSince[itemID] > GIVE_UP_AFTER then
        -- never write the item off: it is parsed again on the next bag change or when its text loads
        gaveUp[itemID] = true
        return
    end
    return nil, nil, nil, true
end

-- Sorts an item into a category. Returns kind, health, mana, notReady, conjured, buff.
local function classify(bag, slot, itemID)
    local cached = infoCache[itemID]
    if cached == false then return end
    if cached then -- already known: only the level / First Aid checks can change
        if (cached.minLevel or 0) > UnitLevel("player") then return end
        if cached.kind == "bandage" and cached.skillNeeded then
            local rank = firstAidRank()
            if rank and rank < cached.skillNeeded then return end
        end
        return cached.kind, cached.health, cached.mana, nil, cached.conjured, cached.buff
    end
    local itemName, _, _, _, minLevel, _, _, _, _, _, _, classID, subClassID = GetItemInfo(itemID)
    if not classID then return notReady(itemID) end
    -- Every item type is checked once (result cached): edible raw fish etc. can be filed
    -- as trade goods / reagents, so only the tooltip text tells us what is food.
    if (minLevel or 0) > UnitLevel("player") then return end
    if cached == nil then
        local info = parseItem(bag, slot, itemID, itemName, classID, subClassID)
        if info == "pending" then return notReady(itemID) end
        if info == "later" then return end -- re-checked by the extra passes after login
        if info then info.minLevel = minLevel or 0 end
        infoCache[itemID] = info
        pendingSince[itemID], gaveUp[itemID] = nil, nil
        cached = info
    end
    if not cached then return end
    if cached.kind == "bandage" and cached.skillNeeded then
        local rank = firstAidRank()
        if rank and rank < cached.skillNeeded then return end
    end
    return cached.kind, cached.health, cached.mana, nil, cached.conjured, cached.buff
end

-- Pick order per group, set with /prov order <group> <high|low> (saved):
--   high = strongest first (default), low = weakest first (use up old stock)
local GROUPS = { food = "food", drink = "food", hpot = "potions", mpot = "potions", bandage = "bandage", stone = "healthstone" }
local function lowFirst(key)
    return ProvisionsCharDB and ProvisionsCharDB.order and ProvisionsCharDB.order[GROUPS[key]] == "low"
end

local function skipBuffFood() return not (ProvisionsDB and ProvisionsDB.skipBuffFood == false) end -- default on
local function conjuredFirst() return not (ProvisionsDB and ProvisionsDB.conjuredFirst == false) end -- default on

-- Ties go to the smaller stack to free bag space.
-- conj: this item is conjured and conjured items should go first (food & drink only)
local function better(cur, value, count, low, conj)
    if value <= 0 then return false end
    if not cur then return true end
    if conj ~= cur.conj then return conj and true or false end -- conjured beats non-conjured, either order
    if value == cur.v then return count < cur.c end
    if low then return value < cur.v end
    return value > cur.v
end

local countOf = (C_Item and C_Item.GetItemCount) or GetItemCount

local function findBest()
    local best = {}
    local cands = {}
    local usable = {} -- IsUsableItem asked once per distinct item per scan, not per bag slot
    -- While dead or a ghost the game calls every item unusable: skip that check then,
    -- so the bar and macros keep showing what you'll use once you're back.
    local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
    local uncached = false
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (bagSlots(bag) or 0) do
            local itemID, count = bagItem(bag, slot)
            if itemID then
                local kind, health, mana, notCached, conjured, buff = classify(bag, slot, itemID)
                if kind == "food" and buff and skipBuffFood() then kind = nil end -- keep buff food for the buff
                local conj = (kind == "food" and conjured and conjuredFirst()) or false
                if notCached then uncached = true end
                if kind and usable[itemID] == nil then usable[itemID] = dead or (not IsUsableItem) or IsUsableItem(itemID) and true or false end
                if kind and usable[itemID] then
                    local hKey = (kind == "food" and "food") or (kind == "potion" and "hpot") or (kind == "stone" and "stone") or "bandage"
                    local mKey = (kind == "food" and "drink") or (kind == "potion" and "mpot") or nil
                    if better(best[hKey], health, count, lowFirst(hKey), conj) then best[hKey] = { id = itemID, v = health, c = count, conj = conj } end
                    if mKey and better(best[mKey], mana, count, lowFirst(mKey), conj) then best[mKey] = { id = itemID, v = mana, c = count, conj = conj } end
                    -- remember every candidate for the right-click list
                    for key, v in pairs({ [hKey] = health, [mKey or "_"] = mana }) do
                        if key ~= "_" and v > 0 then
                            cands[key] = cands[key] or {}
                            cands[key][itemID] = cands[key][itemID] or { id = itemID, v = v, conj = conj }
                        end
                    end
                end
            end
        end
    end
    -- your own pick (right-click on the item bar) wins while you still have that item
    local ov = ProvisionsCharDB and ProvisionsCharDB.override
    if ov then
        for key, id in pairs(ov) do
            local cand = cands[key] and cands[key][id]
            if cand then
                best[key] = { id = id, v = cand.v, c = 1, conj = cand.conj, override = true }
            elseif not uncached and countOf and (countOf(id) or 0) == 0 then
                ov[key] = nil -- ran out: back to strongest/weakest
            end
        end
    end
    lastCands = cands
    if not usesMana() then best.drink, best.mpot = nil, nil end
    return best, uncached
end

local function none(what)
    return "/run print(\"|cff33ff99Provisions|r: no usable " .. what .. " in your bags\")"
end

local function eatDrinkBody(food, drink)
    local lines = { "#showtooltip" }
    if food and drink and food.id == drink.id then
        lines[#lines + 1] = "/use item:" .. food.id
    else
        if food then lines[#lines + 1] = "/use item:" .. food.id end
        if drink then lines[#lines + 1] = "/use item:" .. drink.id end
    end
    if not food and not drink then lines[#lines + 1] = none("food or drink") end
    return table.concat(lines, "\n")
end

local function simpleBody(pick, what, prefix)
    if not pick then return "#showtooltip\n" .. none(what) end
    return "#showtooltip\n/use " .. (prefix or "") .. "item:" .. pick.id
end

local function splitFood() return (ProvisionsDB and ProvisionsDB.splitFood) == true end

-- create = false: only keep an existing macro up to date, never create it
local function setMacro(name, body, create)
    local index = GetMacroIndexByName(name)
    if index == 0 then
        if create == false then return end
        local general = GetNumMacros()
        if general >= (MAX_ACCOUNT_MACROS or 120) then
            print("|cff33ff99Provisions|r: no free general macro slot for \"" .. name .. "\". Delete one in /macro and /reload.")
            return
        end
        CreateMacro(name, MACRO_ICON, body, false)
        return true
    end
    local _, _, oldBody = GetMacroInfo(index)
    if oldBody ~= body then EditMacro(index, name, MACRO_ICON, body) end
end

local function update()
    if InCombatLockdown() then pending = true; return end
    pending = false
    local best, uncached = findBest()
    lastPick = best
    local created = {}
    local macros = {
        -- food & drink: the chosen mode's macros are created; the others are only kept up to date
        { "EatDrink", eatDrinkBody(best.food, best.drink), not splitFood() },
        { "Eat", simpleBody(best.food, "food"), splitFood() },
        { "Drink", simpleBody(best.drink, "drink"), splitFood() },
        { "HealPot", simpleBody(best.hpot, "healing potion") },
        { "ManaPot", simpleBody(best.mpot, "mana potion") },
        { "Bandage", simpleBody(best.bandage, "bandage") },
        { "Healthstone", simpleBody(best.stone, "healthstone") },
    }
    for _, m in ipairs(macros) do
        if setMacro(m[1], m[2], m[3]) then created[#created + 1] = m[1] end
    end
    if #created > 0 then
        print("|cff33ff99Provisions|r: created macro(s) " .. table.concat(created, ", ") .. ". Type /prov and drag them from the Item order tab onto your bars.")
    end
    if uncached then
        retries = retries + 1
        if retries <= 30 and not retryPending then
            retryPending = true
            C_Timer.After(2, function() retryPending = false; update() end)
        end
        waitingForData = retries <= 30
    else
        retries = 0
        waitingForData = false
    end
    if panelRefresh then panelRefresh() end
    safeBarRefresh()
end

local queued = false
local function queueUpdate()
    if queued then return end
    queued = true
    C_Timer.After(0.5, function() queued = false; update() end)
end

f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pending then queueUpdate() end
        safeBarRefresh() -- applies any layout changes that had to wait for combat to end
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT"
        or event == "SPELL_TEXT_UPDATE" or event == "SPELL_DATA_LOAD_RESULT" then
        -- rescan while any item in the bags still lacks its text (cheap: throttled, cache hits otherwise)
        if waitingForData or next(pendingSince) then queueUpdate() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        retries = 0
        settleStart = GetTime()
        queueUpdate()
        -- bags and item data can arrive late after a fresh start: check again a few times
        for _, t in ipairs({ 3, 8, 15, 30, 40 }) do C_Timer.After(t, queueUpdate) end
    else
        -- in combat the rescan has to wait, so update the bar's counts right away
        if event == "BAG_UPDATE_DELAYED" and InCombatLockdown() then safeBarRefresh() end
        queueUpdate()
    end
end)
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_LEVEL_UP", "PLAYER_REGEN_ENABLED",
                     "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
                     "SKILL_LINES_CHANGED", "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT",
                     "SPELL_TEXT_UPDATE", "SPELL_DATA_LOAD_RESULT" }) do
    pcall(f.RegisterEvent, f, e)
end

---------------------------------------------------------------- settings panel (EllesmereUI look)
local OPTIONS = {
    { header = "ITEM ORDER" },
    { group = "food",        label = "Food & drink", picks = { "food", "drink" },
      macros = { { "EatDrink", "food", "combined" }, { "Eat", "food", "split" }, { "Drink", "drink", "split" } } },
    { group = "potions",     label = "Potions",      picks = { "hpot", "mpot" },
      macros = { { "HealPot", "hpot" }, { "ManaPot", "mpot" } } },
    { group = "bandage",     label = "Bandages",     picks = { "bandage" },       macros = { { "Bandage", "bandage" } } },
    { group = "healthstone", label = "Healthstones", picks = { "stone" },         macros = { { "Healthstone", "stone" } } },
    { header = "OPTIONS" },
    { kind = "split",    label = "Food & drink buttons", desc = "One button for both, or separate Eat and Drink buttons" },
    { kind = "conjured", label = "Conjured first",       desc = "Mage food and water is used before anything else, in either order" },
    { kind = "buff",     label = "Skip buff food",       desc = "Food that makes you Well Fed stays in your bags for the buff" },
    { header = "ITEM BAR" },
    { kind = "bar",      label = "Item bar",             desc = "Shows what each button uses and how many are left. Right-click an icon on the bar to pick a specific item." },
    { kind = "barItems", label = "Show on the bar",      desc = "Only items you actually have are shown. Drink and mana potion only on classes with mana." },
    { kind = "barSize",  label = "Icon size",            desc = "Size of the icons on the bar" },
    { kind = "barGrow",  label = "Grow direction",       desc = "The bar stays pinned on the side it grows away from" },
    { header = "BAR BEHAVIOUR", sub = 2 }, -- second page of the Item bar tab
    { kind = "barLock",  label = "Position",             desc = "Unlock to drag the bar, then lock it again. Tip: Alt + click on the bar unlocks it too." },
    { kind = "barClickable", label = "Clickable",        desc = "Left-click uses the item. During combat the bar's layout is frozen (game rule)." },
    { kind = "barClick", label = "Click-through when locked", desc = "Clicks go through the bar to the game world (no tooltips). Holding Alt still lets you Alt + click to unlock it." },
}

local BAR_ITEMS = {
    { "food", "Food" }, { "drink", "Drink" }, { "hpot", "Heal pot" },
    { "mpot", "Mana pot" }, { "bandage", "Bandage" }, { "stone", "Stone" },
}
local function barDB()
    ProvisionsDB = ProvisionsDB or {}
    ProvisionsDB.bar = ProvisionsDB.bar or {}
    local b = ProvisionsDB.bar -- shared by all characters
    if b.shown == nil then b.shown = true end
    if b.locked == nil then b.locked = false end       -- first install: unlocked, so it can be placed
    if b.clickable == nil then b.clickable = true end
    if b.clickThrough == nil then b.clickThrough = false end
    if b.iconSize == nil then b.iconSize = 32 end
    if b.grow == nil then b.grow = "RIGHT" end
    return b
end
-- which item types the bar shows: per character
local function barItems()
    ProvisionsCharDB = ProvisionsCharDB or {}
    ProvisionsCharDB.barItems = ProvisionsCharDB.barItems or {}
    local t = ProvisionsCharDB.barItems
    for _, it in ipairs(BAR_ITEMS) do if t[it[1]] == nil then t[it[1]] = true end end
    return t
end

local function itemIcon(id)
    local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    return id and instant and select(5, instant(id))
end

local function getOrder(group)
    return (ProvisionsCharDB and ProvisionsCharDB.order and ProvisionsCharDB.order[group]) or "high"
end
local function setOrder(group, mode)
    ProvisionsCharDB = ProvisionsCharDB or {}
    ProvisionsCharDB.order = ProvisionsCharDB.order or {}
    ProvisionsCharDB.order[group] = mode
end

local function accent()
    local g = EllesmereUI and EllesmereUI.ELLESMERE_GREEN
    if g and g.r then return g.r, g.g, g.b end
    return 0.05, 0.82, 0.62
end

local function fontPath()
    if EllesmereUI and EllesmereUI.GetFontPath then
        local ok, path = pcall(EllesmereUI.GetFontPath)
        if ok and path then return path end
    end
    return STANDARD_TEXT_FONT
end

-- 1px edges around a frame (pixel-exact at any UI scale)
local function addEdges(frame, r, g, b, a, layer)
    local edges = {}
    local px = 1 / (frame:GetEffectiveScale() or 1)
    local function edge() local t = frame:CreateTexture(nil, layer or "BORDER"); t:SetColorTexture(r, g, b, a); edges[#edges + 1] = t; return t end
    local t = edge(); t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(px)
    local bt = edge(); bt:SetPoint("BOTTOMLEFT"); bt:SetPoint("BOTTOMRIGHT"); bt:SetHeight(px)
    local l = edge(); l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(px)
    local rt = edge(); rt:SetPoint("TOPRIGHT"); rt:SetPoint("BOTTOMRIGHT"); rt:SetWidth(px)
    function edges:SetColor(r2, g2, b2, a2) for _, e in ipairs(self) do e:SetColorTexture(r2, g2, b2, a2) end end
    return edges
end

local panel
local function buildPanel()
    local FONT = fontPath()
    local ar, ag, ab = accent()
    local W, PAD, ROW_H = 420, 18, 56
    local SEG_W, SEG_H = 74, 22               -- one half of the Strongest|Weakest switch
    local ICON, ICON_COL = 28, 66             -- macro icons on the left of each row

    panel = CreateFrame("Frame", "ProvisionsPanel", UIParent)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    tinsert(UISpecialFrames, "ProvisionsPanel") -- Escape closes it

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.077, 0.068, 0.058, 0.97)
    addEdges(panel, 1, 1, 1, 0.15)
    local top = panel:CreateTexture(nil, "ARTWORK")
    top:SetColorTexture(ar, ag, ab, 0.9)
    top:SetPoint("TOPLEFT", 1, -1); top:SetPoint("TOPRIGHT", -1, -1); top:SetHeight(2)

    local eyebrow = panel:CreateFontString(nil, "OVERLAY")
    eyebrow:SetFont(FONT, 12, "")
    eyebrow:SetTextColor(ar, ag, ab, 0.9)
    eyebrow:SetPoint("TOPLEFT", PAD, -16)
    eyebrow:SetText("PROVISIONS")
    local title = panel:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 19, "")
    title:SetTextColor(1, 1, 1, 1)
    title:SetPoint("TOPLEFT", eyebrow, "BOTTOMLEFT", 0, -4)
    title:SetText("Settings")
    local desc = panel:CreateFontString(nil, "OVERLAY")
    desc:SetFont(FONT, 12, "")
    desc:SetTextColor(1, 1, 1, 0.45)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    desc:SetWidth(W - PAD * 2)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetText("Drag an icon onto your action bars. Item order picks which item each button uses first; Weakest uses up old stock.")

    local close = CreateFrame("Button", nil, panel)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -8, -8)
    local x = close:CreateFontString(nil, "OVERLAY")
    x:SetFont(FONT, 18, "")
    x:SetPoint("CENTER")
    x:SetText("×")
    x:SetTextColor(1, 1, 1, 0.5)
    close:SetScript("OnEnter", function() x:SetTextColor(1, 1, 1, 0.9) end)
    close:SetScript("OnLeave", function() x:SetTextColor(1, 1, 1, 0.5) end)
    close:SetScript("OnClick", function() panel:Hide() end)

    -- thin divider under the header
    local div = panel:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(1, 1, 1, 0.08)
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    div:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)

    -- one half of the switch
    local function segment(parent, text)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(SEG_W, SEG_H)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.edges = addEdges(b, 1, 1, 1, 0.18)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetFont(FONT, 12, "")
        b.text:SetPoint("CENTER", 0, 0)
        b.text:SetText(text)
        function b:SetActive(on)
            if on then
                self.bg:SetColorTexture(ar, ag, ab, 0.9)
                self.edges:SetColor(ar, ag, ab, 1)
                self.text:SetTextColor(0.05, 0.05, 0.05, 1)
            else
                self.bg:SetColorTexture(0.075, 0.113, 0.141, 1)
                self.edges:SetColor(1, 1, 1, 0.18)
                self.text:SetTextColor(1, 1, 1, 0.5)
            end
            self.active = on
        end
        b:SetScript("OnEnter", function(self) if not self.active then self.text:SetTextColor(1, 1, 1, 0.85) end end)
        b:SetScript("OnLeave", function(self) if not self.active then self.text:SetTextColor(1, 1, 1, 0.5) end end)
        return b
    end

    -- tabs: one per section heading in OPTIONS
    local TAB_NAMES = { "Item order", "Options", "Item bar" }
    local SUB_TAB = 3                                  -- the Item bar tab has two pages
    local SUB_NAMES = { "Appearance", "Behaviour" }
    local activeTab = (ProvisionsDB and ProvisionsDB.tab) or 1
    local activeSub = (ProvisionsDB and ProvisionsDB.subTab) or 1
    if activeTab > #TAB_NAMES then activeTab, activeSub = SUB_TAB, 2 end -- older 4-tab layout
    local tabW = math.floor((W - PAD * 2) / #TAB_NAMES)
    local tabs = {}
    for t, name in ipairs(TAB_NAMES) do
        local b = segment(panel, name)
        b:SetSize(tabW + 1, SEG_H + 4)
        b:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", (t - 1) * tabW, -12)
        b:SetScript("OnClick", function()
            activeTab = t
            ProvisionsDB = ProvisionsDB or {}
            ProvisionsDB.tab = t
            panelRefresh()
        end)
        tabs[t] = b
    end
    div:ClearAllPoints()
    div:SetPoint("TOPLEFT", tabs[1], "BOTTOMLEFT", 0, -10)
    div:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)

    -- sub-switch at the top of the Item bar tab: Appearance | Behaviour
    local subBar = CreateFrame("Frame", nil, panel)
    subBar:SetHeight(SEG_H + 12)
    local subs = {}
    for t, name in ipairs(SUB_NAMES) do
        local b = segment(subBar, name)
        b:SetSize(110, SEG_H)
        if t == 1 then b:SetPoint("TOPLEFT", subBar, "TOPLEFT", 0, -6)
        else b:SetPoint("LEFT", subs[t - 1], "RIGHT", -1, 0) end
        b:SetScript("OnClick", function()
            activeSub = t
            ProvisionsDB = ProvisionsDB or {}
            ProvisionsDB.subTab = t
            panelRefresh()
        end)
        subs[t] = b
    end

    panel.rows = {}
    local prev = div
    local section, subsection = 0, 1
    for i, opt in ipairs(OPTIONS) do
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, i == 1 and -6 or 0)
        row:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
        prev = row
        if opt.header and not opt.sub then section = section + 1; subsection = 1 end
        if opt.sub then subsection = opt.sub end
        row.section, row.sub = section, subsection
        row.isHeader = opt.header and true or false
        if opt.header then
            -- small section heading
            row:SetHeight(i == 1 and 22 or 34)
            local h = row:CreateFontString(nil, "OVERLAY")
            h:SetFont(FONT, 11, "")
            h:SetTextColor(ar, ag, ab, 0.85)
            h:SetPoint("BOTTOMLEFT", 0, 4)
            h:SetText(opt.header)
            function row:Refresh() end
        else
        local indent = opt.kind and 0 or ICON_COL -- option rows have no icons

        -- draggable macro icons
        local icons = {}
        for m, info in ipairs(opt.macros or {}) do
            local macroName, pickKey, mode = info[1], info[2], info[3]
            local b = CreateFrame("Button", nil, row)
            b:SetSize(ICON, ICON)
            b.mode = mode -- nil = always shown, "combined"/"split" = only in that food & drink mode
            b.tex = b:CreateTexture(nil, "ARTWORK")
            b.tex:SetPoint("TOPLEFT", 1, -1); b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
            b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            b.edges = addEdges(b, 1, 1, 1, 0.2, "OVERLAY")
            b:RegisterForDrag("LeftButton")
            local function pickup()
                if InCombatLockdown() then
                    print("|cff33ff99Provisions|r: can't place macros in combat")
                    return
                end
                local index = GetMacroIndexByName(macroName)
                if index and index > 0 then PickupMacro(index)
                else print("|cff33ff99Provisions|r: macro \"" .. macroName .. "\" doesn't exist yet (no free general macro slot?)") end
            end
            b:SetScript("OnDragStart", pickup)
            b:SetScript("OnClick", pickup)
            b:SetScript("OnEnter", function(self)
                self.edges:SetColor(ar, ag, ab, 1)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(macroName)
                GameTooltip:AddLine("Drag to your action bars", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function(self)
                self.edges:SetColor(1, 1, 1, 0.2)
                GameTooltip:Hide()
            end)
            function b:Refresh()
                local p = lastPick[pickKey]
                self.tex:SetTexture(itemIcon(p and p.id) or MACRO_ICON)
                self.tex:SetDesaturated(not p)
                self.tex:SetAlpha(p and 1 or 0.4)
            end
            icons[m] = b
        end

        local lbl = row:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 15, "")
        lbl:SetTextColor(1, 1, 1, 0.9)
        lbl:SetPoint("TOPLEFT", indent, -11)
        lbl:SetWidth(W - PAD * 2 - indent - SEG_W * 2 - 12) -- never runs into the switch
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(false)
        lbl:SetText(opt.label)
        local sub = row:CreateFontString(nil, "OVERLAY")
        sub:SetFont(FONT, 11, "")
        sub:SetTextColor(1, 1, 1, 0.38)
        sub:SetPoint("TOPLEFT", row, "TOPLEFT", indent, -(8 + SEG_H + 6)) -- below the switch
        sub:SetWidth(W - PAD * 2 - indent)                               -- full row width
        sub:SetJustifyH("LEFT")
        sub:SetWordWrap(true)
        if sub.SetMaxLines then sub:SetMaxLines(2) end

        if opt.kind == "barSize" then
        local MIN, MAX = 20, 56
        local val = row:CreateFontString(nil, "OVERLAY")
        val:SetFont(FONT, 13, "")
        val:SetTextColor(ar, ag, ab, 1)
        val:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -12)
        local slider = CreateFrame("Slider", nil, row)
        slider:SetOrientation("HORIZONTAL")
        slider:SetHeight(16)
        slider:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -(8 + SEG_H + 8))
        slider:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        slider:SetMinMaxValues(MIN, MAX)
        slider:SetValueStep(2)
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
        local track = slider:CreateTexture(nil, "BACKGROUND")
        track:SetColorTexture(0.075, 0.113, 0.141, 1)
        track:SetHeight(6)
        track:SetPoint("LEFT"); track:SetPoint("RIGHT")
        local fill = slider:CreateTexture(nil, "BORDER")
        fill:SetColorTexture(ar, ag, ab, 0.6)
        fill:SetHeight(6)
        fill:SetPoint("LEFT", track, "LEFT")
        local thumb = slider:CreateTexture(nil, "ARTWORK")
        thumb:SetColorTexture(ar, ag, ab, 1)
        thumb:SetSize(10, 16)
        slider:SetThumbTexture(thumb)
        local updating = false
        local function show(v)
            val:SetText(math.floor(v + 0.5) .. " px")
            local w = slider:GetWidth() or 0
            fill:SetWidth(math.max(1, w * (v - MIN) / (MAX - MIN)))
        end
        slider:SetScript("OnValueChanged", function(_, v)
            v = math.floor(v / 2 + 0.5) * 2
            show(v)
            if updating then return end
            if not barChangeAllowed() then return end
            barDB().iconSize = v
            safeBarRefresh()
        end)
        sub:ClearAllPoints()
        sub:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -(8 + SEG_H + 8 + 16 + 6))
        function row:Refresh()
            local v = barDB().iconSize
            updating = true
            slider:SetValue(v)
            updating = false
            show(v)
            sub:SetText(opt.desc)
            self:SetHeight(8 + SEG_H + 8 + 16 + 6 + sub:GetStringHeight() + 10)
        end
        elseif opt.kind == "barItems" then
        -- one toggle chip per item type
        local chipW = math.floor((W - PAD * 2) / #BAR_ITEMS)
        local chips = {}
        for c, it in ipairs(BAR_ITEMS) do
            local b = segment(row, it[2])
            b:SetSize(chipW + 1, SEG_H)
            b:SetPoint("TOPLEFT", row, "TOPLEFT", (c - 1) * chipW, -(8 + SEG_H + 6))
            b:SetScript("OnClick", function()
                if not barChangeAllowed() then return end
                local items = barItems()
                items[it[1]] = not items[it[1]]
                safeBarRefresh()
                panelRefresh()
            end)
            chips[c] = b
        end
        sub:ClearAllPoints()
        sub:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -(8 + SEG_H + 6 + SEG_H + 6))
        function row:Refresh()
            local items = barItems()
            for c, it in ipairs(BAR_ITEMS) do chips[c]:SetActive(items[it[1]] and true or false) end
            sub:SetText(opt.desc)
            self:SetHeight(8 + SEG_H + 6 + SEG_H + 6 + sub:GetStringHeight() + 10)
        end
        else
        -- two-way switch: item order for item rows, combined/separate for the food & drink mode row
        local choices, get, set
        if opt.kind == "barClickable" then
            choices = { { "On", true }, { "Off", false } }
            get = function() return barDB().clickable and true or false end
            set = function(v)
                if InCombatLockdown() then
                    print("|cff33ff99Provisions|r: Clickable can only be switched outside combat")
                    return
                end
                barDB().clickable = v
                safeBarRefresh()
            end
        elseif opt.kind == "barGrow" then
            choices = { { "Right", "RIGHT" }, { "Left", "LEFT" }, { "Up", "UP" }, { "Down", "DOWN" } }
            get = function() return barDB().grow end
            set = function(v) setBarGrow(v) end
        elseif opt.kind == "barLock" then
            choices = { { "Locked", true }, { "Unlocked", false } }
            get = function() return barDB().locked end
            set = function(v) if barChangeAllowed() then barDB().locked = v; safeBarRefresh() end end
        elseif opt.kind == "barClick" then
            choices = { { "On", true }, { "Off", false } }
            get = function() return barDB().clickThrough end
            set = function(v) if barChangeAllowed() then barDB().clickThrough = v; safeBarRefresh() end end
        elseif opt.kind == "bar" then
            choices = { { "Show", true }, { "Hide", false } }
            get = function() return barDB().shown end
            set = function(v) if barChangeAllowed() then barDB().shown = v; safeBarRefresh() end end
        elseif opt.kind == "buff" then
            choices = { { "On", true }, { "Off", false } }
            get = skipBuffFood
            set = function(v) ProvisionsDB = ProvisionsDB or {}; ProvisionsDB.skipBuffFood = v end
        elseif opt.kind == "conjured" then
            choices = { { "On", true }, { "Off", false } }
            get = conjuredFirst
            set = function(v) ProvisionsDB = ProvisionsDB or {}; ProvisionsDB.conjuredFirst = v end
        elseif opt.kind == "split" then
            choices = { { "Combined", false }, { "Separate", true } }
            get = splitFood
            set = function(v) ProvisionsDB = ProvisionsDB or {}; ProvisionsDB.splitFood = v end
        else
            choices = { { "Strongest", "high" }, { "Weakest", "low" } }
            get = function() return getOrder(opt.group) end
            set = function(v) setOrder(opt.group, v) end
        end
        -- one segment per choice, built right to left; 4-way switches use narrower segments
        local segW = (#choices > 2) and 52 or SEG_W
        local segs = {}
        for c = #choices, 1, -1 do
            local b = segment(row, choices[c][1])
            b:SetSize(segW, SEG_H)
            if c == #choices then b:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -8)
            else b:SetPoint("RIGHT", segs[c + 1], "LEFT", 1, 0) end -- overlap 1px so the edges merge
            segs[c] = b
        end

        if OPTIONS[i + 1] and not OPTIONS[i + 1].header then
            local line = row:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(1, 1, 1, 0.05)
            line:SetHeight(1)
            line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT")
        end

        function row:Refresh()
            local n = 0
            for _, b in ipairs(icons) do
                local show = not b.mode or ((b.mode == "split") == splitFood())
                b:SetShown(show)
                if show then
                    b:ClearAllPoints()
                    b:SetPoint("TOPLEFT", row, "TOPLEFT", n * (ICON + 6), -5)
                    n = n + 1
                    b:Refresh()
                end
            end
            local cur = get()
            for c, b in ipairs(segs) do b:SetActive(cur == choices[c][2]) end
            if opt.kind then
                sub:SetText(opt.desc)
            else
                local names = {}
                for _, key in ipairs(opt.picks) do
                    local p = lastPick[key]
                    if p then
                        local n = GetItemInfo(p.id) or ("item " .. p.id)
                        if p.override then n = n .. " (your pick - right-click it on the bar to change)" end
                        names[#names + 1] = n
                    end
                end
                sub:SetText(#names > 0 and ("Now: " .. table.concat(names, " + ")) or "Now: none in bags")
            end
            self:SetHeight(math.max(ROW_H, 8 + SEG_H + 6 + sub:GetStringHeight() + 10))
        end
        local function choose(v)
            if get() == v then return end
            set(v)
            update()
            row:Refresh()
        end
        for c, b in ipairs(segs) do b:SetScript("OnClick", function() choose(choices[c][2]) end) end
        end -- switch row
        end -- not a header
        panel.rows[i] = row
    end

    local hint = panel:CreateFontString(nil, "OVERLAY")
    hint:SetFont(FONT, 11, "")
    hint:SetTextColor(1, 1, 1, 0.3)
    hint:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -10)
    hint:SetWidth(W - PAD * 2)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Changes apply right away, or as soon as combat ends.")

    -- size the window to its content (text heights depend on the font in use)
    local function layoutRows()
        local last = nil
        local paged = (activeTab == SUB_TAB)
        subBar:SetShown(paged)
        if paged then
            subBar:ClearAllPoints()
            subBar:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -2)
            subBar:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
            for t, b in ipairs(subs) do b:SetActive(t == activeSub) end
            last = subBar
        end
        for _, r in ipairs(panel.rows) do
            local show = (r.section == activeTab) and not r.isHeader and (not paged or r.sub == activeSub)
            r:SetShown(show)
            if show then
                r:ClearAllPoints()
                if last then r:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0)
                else r:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -4) end
                r:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
                last = r
            end
        end
        -- footer: hint pinned to the bottom edge with a thin line above it
        hint:ClearAllPoints()
        hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, 14)
        hint:SetWidth(W - PAD * 2)
        if not panel.footerLine then
            panel.footerLine = panel:CreateTexture(nil, "ARTWORK")
            panel.footerLine:SetColorTexture(1, 1, 1, 0.08)
            panel.footerLine:SetHeight(1)
        end
        panel.footerLine:ClearAllPoints()
        panel.footerLine:SetPoint("BOTTOMLEFT", hint, "TOPLEFT", 0, 10)
        panel.footerLine:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
        for t, b in ipairs(tabs) do b:SetActive(t == activeTab) end
    end
    local function rowsHeight(section, sub)
        local h = 0
        for _, r in ipairs(panel.rows) do
            if r.section == section and not r.isHeader and (not sub or r.sub == sub) then
                h = h + (r:GetHeight() or ROW_H)
            end
        end
        return h
    end
    -- One fixed height for all tabs (the tallest one), so switching tabs never resizes the window
    local function layout()
        layoutRows()
        local tallest = 0
        for t = 1, #TAB_NAMES do
            if t == SUB_TAB then
                for sub = 1, #SUB_NAMES do tallest = math.max(tallest, subBar:GetHeight() + 2 + rowsHeight(t, sub)) end
            else
                tallest = math.max(tallest, rowsHeight(t))
            end
        end
        local header = 16 + eyebrow:GetStringHeight() + 4 + title:GetStringHeight() + 6 + desc:GetStringHeight()
            + 12 + SEG_H + 4 + 10
        local top, divBottom = panel:GetTop(), div:GetBottom()
        if top and divBottom and top > divBottom then header = top - divBottom end -- measured when available
        local footer = 12 + 1 + 10 + hint:GetStringHeight() + 14
        panel:SetSize(W, math.floor(header + 4 + tallest + footer + 0.5))
    end
    layout()

    panelRefresh = function()
        if not panel:IsShown() then return end
        for _, r in ipairs(panel.rows) do r:Refresh() end
        layout()
    end
    panel:SetScript("OnShow", function()
        layout(); panelRefresh()
        C_Timer.After(0, function() if panel:IsShown() then layout() end end) -- positions settle next frame
    end)
end

local function togglePanel()
    if not panel then buildPanel() end
    if panel:IsShown() then panel:Hide() else panel:Show(); panelRefresh() end
end

---------------------------------------------------------------- item bar
-- Display only: icon + count of what each button currently uses. Drag to move.
local BAR_SIZE, BAR_GAP = 32, 4
local bar
local getCount = (C_Item and C_Item.GetItemCount) or GetItemCount

-- The bar is pinned at the edge it grows away from
local GROW_ANCHOR = { RIGHT = "LEFT", LEFT = "RIGHT", UP = "BOTTOM", DOWN = "TOP" }

local function anchorCoords(anchor)
    local l, r, t, b = bar:GetLeft(), bar:GetRight(), bar:GetTop(), bar:GetBottom()
    if not (l and r and t and b) then return end
    if anchor == "LEFT" then return l, (t + b) / 2
    elseif anchor == "RIGHT" then return r, (t + b) / 2
    elseif anchor == "BOTTOM" then return (l + r) / 2, b
    else return (l + r) / 2, t end
end

local function applyBarAnchor()
    local db = barDB()
    if not db.pos then return end
    if bar.sslots and InCombatLockdown() then return end
    bar:ClearAllPoints()
    bar:SetPoint(GROW_ANCHOR[db.grow] or "LEFT", UIParent, "BOTTOMLEFT", db.pos[1], db.pos[2])
end

local function saveBarPos()
    local db = barDB()
    local x, y = anchorCoords(GROW_ANCHOR[db.grow] or "LEFT")
    if x then db.pos = { x, y }; db.point = nil end
end

local function buildBar()
    local FONT = fontPath()
    local ar, ag, ab = accent()
    local db = barDB()
    bar = CreateFrame("Frame", "ProvisionsBar", UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    local function startMove()
        if barDB().locked or (bar.sslots and InCombatLockdown()) then return end
        bar:StartMoving()
    end
    local function stopMove()
        bar:StopMovingOrSizing()
        saveBarPos()
        applyBarAnchor()
    end
    bar:SetScript("OnDragStart", startMove)
    bar:SetScript("OnDragStop", stopMove)
    bar:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and IsAltKeyDown() then unlockBar() end
    end)
    if db.pos then applyBarAnchor()
    elseif db.point then bar:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4]) -- older versions
    else bar:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.077, 0.068, 0.058, 0.85)
    bar.edges = addEdges(bar, 1, 1, 1, 0.15)
    bar.dragLabel = bar:CreateFontString(nil, "OVERLAY")
    bar.dragLabel:SetFont(FONT, 11, "OUTLINE")
    bar.dragLabel:SetTextColor(ar, ag, ab, 1)

    bar.dragLabel:SetText("drag to move")
    bar.accent = { ar, ag, ab }

    -- small buttons above the bar, only while unlocked: lock it / open settings
    local function miniButton(icon, tip, onClick)
        local b = CreateFrame("Button", nil, bar)
        b:SetSize(18, 18)
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetPoint("TOPLEFT", 1, -1); t:SetPoint("BOTTOMRIGHT", -1, 1)
        t:SetTexture(icon)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local e = addEdges(b, 1, 1, 1, 0.3, "OVERLAY")
        b:SetScript("OnEnter", function(self)
            e:SetColor(ar, ag, ab, 1)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(tip)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() e:SetColor(1, 1, 1, 0.3); GameTooltip:Hide() end)
        b:SetScript("OnClick", onClick)
        b:Hide()
        return b
    end
    bar.lockBtn = miniButton("Interface\\Icons\\INV_Misc_Key_03", "Lock the bar in place", function()
        if not barChangeAllowed() then return end
        barDB().locked = true
        GameTooltip:Hide()
        safeBarRefresh()
        if panelRefresh then panelRefresh() end
    end)
    bar.lockBtn:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, 3)
    bar.gearBtn = miniButton("Interface\\Icons\\INV_Misc_Gear_01", "Provisions settings", function()
        GameTooltip:Hide()
        if not (ProvisionsPanel and ProvisionsPanel:IsShown()) then togglePanel() end -- open, never close
    end)
    bar.gearBtn:SetPoint("RIGHT", bar.lockBtn, "LEFT", -4, 0)
    bar.dragLabel:SetPoint("RIGHT", bar.gearBtn, "LEFT", -6, 0) -- label, gear, lock in one row

    bar.startMove, bar.stopMove = startMove, stopMove
    bar.slots = {}
    for i, it in ipairs(BAR_ITEMS) do bar.slots[i] = makeSlot(i, it, false) end
end

-- Builds one icon. secure = a protected button that uses the item when clicked
-- (only ever created/changed outside combat).
makeSlot = function(i, it, secure)
    local FONT = fontPath()
    local ar, ag, ab = accent()
    local slot
    if secure then
        slot = CreateFrame("Button", "ProvisionsBarButton" .. i, bar, "SecureActionButtonTemplate")
        slot:RegisterForClicks("AnyUp")
        -- With the "use on key down" game setting (default on), the secure handler would otherwise
        -- only act on mouse-down and ignore our mouse-up clicks
        slot:SetAttribute("useOnKeyDown", false)
        slot:SetAttribute("alt-type1", "macro")   -- Alt + left-click is reserved for unlocking:
        slot:SetAttribute("alt-macrotext1", "")   -- an empty macro, so nothing gets used
    else
        slot = CreateFrame("Frame", nil, bar)
    end
    slot:SetSize(BAR_SIZE, BAR_SIZE)
    slot:EnableMouse(true)
    slot:RegisterForDrag("LeftButton")
    slot:SetScript("OnDragStart", bar.startMove) -- dragging an icon moves the whole bar
    slot:SetScript("OnDragStop", bar.stopMove)
    slot.tex = slot:CreateTexture(nil, "ARTWORK")
    slot.tex:SetPoint("TOPLEFT", 1, -1); slot.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    slot.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    slot.edges = addEdges(slot, 1, 1, 1, 0.2, "OVERLAY")
    slot.count = slot:CreateFontString(nil, "OVERLAY")
    slot.count:SetFont(FONT, 12, "OUTLINE")
    slot.count:SetPoint("BOTTOMRIGHT", -2, 2)
    slot:SetScript("OnEnter", function(self)
        self.edges:SetColor(ar, ag, ab, 1)
        if not (tooltipBesideFlyout and tooltipBesideFlyout(self)) then GameTooltip:SetOwner(self, "ANCHOR_TOP") end
        if self.itemID and GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID)
        else GameTooltip:AddLine(it[2] .. ": none in bags") end
        -- Provisions' own section under the item text
        local db = barDB()
        local ov = ProvisionsCharDB and ProvisionsCharDB.override and ProvisionsCharDB.override[self.key]
        local function hintLine(key, text) GameTooltip:AddDoubleLine(key, text, 1, 1, 1, 0.7, 0.7, 0.7) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(ov and "Provisions - your pick" or "Provisions", ar, ag, ab)
        if self.secure and db.locked then hintLine("Left-click", "use") end
        hintLine("Right-click", ov and "change your pick" or "pick a different item")
        if db.locked then hintLine("Alt + click", "unlock the bar") end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function(self)
        self.edges:SetColor(1, 1, 1, 0.2)
        GameTooltip:Hide()
    end)
    slot.secure = secure
    slot.key = it[1]
    if secure then
        slot:HookScript("OnClick", function(self, button)
            if button == "RightButton" then openFlyout(self, self.key)
            elseif button == "LeftButton" and IsAltKeyDown() then unlockBar() end
        end)
    else
        slot:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" then openFlyout(self, self.key)
            elseif button == "LeftButton" and IsAltKeyDown() then unlockBar() end
        end)
    end
    slot:Hide()
    return slot
end

-- While protected buttons exist, the game forbids changing the bar's layout in combat
local function barFrozen() return bar and bar.sslots and InCombatLockdown() end
local layoutPending = false

local function setCount(slot, count)
    slot.count:SetText(count)
    slot.tex:SetDesaturated(count == 0)
    slot.tex:SetAlpha(count == 0 and 0.4 or 1)
    if count == 0 then slot.count:SetTextColor(1, 0.35, 0.3) else slot.count:SetTextColor(1, 1, 1) end
end

barRefresh = function()
    local db = barDB()
    -- In combat with clickable buttons: only numbers/greying may change. Layout waits for combat to end.
    if barFrozen() then
        for _, set in ipairs({ bar.slots, bar.sslots }) do
            for _, slot in ipairs(set) do
                if slot:IsShown() and slot.itemID then setCount(slot, (getCount and getCount(slot.itemID)) or 0) end
            end
        end
        layoutPending = true
        return
    end
    layoutPending = false
    if not db.shown then if bar then bar:Hide() end return end
    if not bar then buildBar() end
    local clickable = db.clickable and true or false
    if clickable and not bar.sslots then -- create the clickable buttons (we are out of combat here)
        bar.sslots = {}
        for i, it in ipairs(BAR_ITEMS) do bar.sslots[i] = makeSlot(i, it, true) end
        bar.curSize = nil
    end
    local active = clickable and bar.sslots or bar.slots
    local inactive = clickable and bar.slots or bar.sslots
    if inactive then for _, slot in ipairs(inactive) do slot:Hide() end end

    local mana = usesMana()
    local items = barItems()
    local unlocked = not db.locked
    local mouse = unlocked or not db.clickThrough -- click-through only applies while locked
    bar:EnableMouse(mouse)
    local size = db.iconSize or BAR_SIZE
    local grow = db.grow or "RIGHT"
    if bar.curSize ~= size then -- resize icons and count text only when the size changed
        bar.curSize = size
        for _, set in ipairs({ bar.slots, bar.sslots or {} }) do
            for _, slot in ipairs(set) do
                slot:SetSize(size, size)
                slot.count:SetFont(fontPath(), math.max(9, math.floor(size * 0.38)), "OUTLINE")
            end
        end
    end
    local n = 0
    for i, it in ipairs(BAR_ITEMS) do
        local key, slot = it[1], active[i]
        local p = lastPick[key]
        local count = (p and getCount and getCount(p.id)) or 0
        -- only what you actually have, only the types you picked, no mana items without mana
        local show = items[key] and count > 0 and (mana or (key ~= "drink" and key ~= "mpot"))
        if show then
            slot:ClearAllPoints()
            local off = BAR_GAP + n * (size + BAR_GAP) -- first icon sits at the pinned edge
            if grow == "LEFT" then slot:SetPoint("RIGHT", bar, "RIGHT", -off, 0)
            elseif grow == "UP" then slot:SetPoint("BOTTOM", bar, "BOTTOM", 0, off)
            elseif grow == "DOWN" then slot:SetPoint("TOP", bar, "TOP", 0, -off)
            else slot:SetPoint("LEFT", bar, "LEFT", off, 0) end
            n = n + 1
            slot.itemID = p.id
            slot.tex:SetTexture(itemIcon(p.id) or MACRO_ICON)
            setCount(slot, count)
            if slot.secure then
                -- unlocked = moving the bar, so clicks don't use anything
                slot:SetAttribute("type1", (not unlocked) and "item" or nil) -- left-click uses; right-click = list
                slot:SetAttribute("item", "item:" .. p.id)
            end
            slot:EnableMouse(mouse)
            slot:Show()
        else
            slot:Hide()
        end
    end
    -- unlocked: accent border + label, and stay visible even when empty so it can be moved
    local ar, ag, ab = bar.accent[1], bar.accent[2], bar.accent[3]
    if unlocked then bar.edges:SetColor(ar, ag, ab, 1) else bar.edges:SetColor(1, 1, 1, 0.15) end
    bar.dragLabel:SetShown(unlocked)
    bar.lockBtn:SetShown(unlocked)
    bar.gearBtn:SetShown(unlocked)
    if n == 0 and not unlocked then bar:Hide(); return end
    local length = BAR_GAP + math.max(n, 1) * (size + BAR_GAP)
    if grow == "UP" or grow == "DOWN" then bar:SetSize(size + BAR_GAP * 2, length)
    else bar:SetSize(length, size + BAR_GAP * 2) end
    bar:Show()
end

-- Bar settings that touch the layout can't change in combat while the bar is clickable
barChangeAllowed = function()
    if barFrozen() or (InCombatLockdown() and barDB().clickable) then
        print("|cff33ff99Provisions|r: the clickable bar can't be changed during combat - try again after the fight")
        return false
    end
    return true
end

setBarGrow = function(v)
    local db = barDB()
    if db.grow == v or not barChangeAllowed() then return end
    db.grow = v
    if bar and bar:IsShown() then saveBarPos() end -- keep the bar where it is, pinned on the new side
    safeBarRefresh()
    if bar then applyBarAnchor() end
end

---------------------------------------------------------------- right-click list (override)
-- Lists every usable item of one type; picking one makes it the choice for the bar and macro
-- until you run out of it. "Auto" goes back to strongest/weakest.
local flyout
local GROUP_OF = { food = "food", drink = "food", hpot = "potions", mpot = "potions", bandage = "bandage", stone = "healthstone" }

local function setOverride(key, id)
    ProvisionsCharDB = ProvisionsCharDB or {}
    ProvisionsCharDB.override = ProvisionsCharDB.override or {}
    ProvisionsCharDB.override[key] = id
    if InCombatLockdown() then
        print("|cff33ff99Provisions|r: your pick applies as soon as combat ends")
    end
    queueUpdate()
end

local function buildFlyout()
    local FONT = fontPath()
    flyout = CreateFrame("Frame", "ProvisionsFlyout", UIParent)
    flyout:SetFrameStrata("DIALOG")
    flyout:SetClampedToScreen(true)
    flyout:EnableMouse(true)
    tinsert(UISpecialFrames, "ProvisionsFlyout") -- Escape closes it
    local bg = flyout:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.077, 0.068, 0.058, 0.95)
    addEdges(flyout, 1, 1, 1, 0.2)
    flyout.buttons = {}
    flyout.font = FONT
    -- close when the mouse has been away from the list and its icon for a moment.
    -- Checked 10x per second; any error closes the list and is reported once (never spams).
    local function over(region)
        if not region or not region.IsMouseOver or not region:IsVisible() then return false end
        local ok, res = pcall(region.IsMouseOver, region)
        return ok and res and true or false
    end
    local away, tick = 0, 0
    flyout:SetScript("OnUpdate", function(self, dt)
        tick = tick + dt
        if tick < 0.1 then return end
        local step = tick
        tick = 0
        local ok, err = pcall(function()
            if over(self) or over(self.owner) then away = 0
            else
                away = away + step
                if away > 1.2 then self:Hide() end
            end
        end)
        if not ok then
            self:Hide()
            ProvisionsCharDB = ProvisionsCharDB or {}
            ProvisionsCharDB.lastError = tostring(err)
            if not self.errorShown then
                self.errorShown = true
                print("|cff33ff99Provisions|r list closed after an error: " .. tostring(err))
            end
        end
    end)
    flyout:SetScript("OnHide", function() away, tick = 0, 0 end)
    flyout:Hide()
end

local function flyoutButton(i)
    local b = flyout.buttons[i]
    if b then return b end
    local ar, ag, ab = accent()
    b = CreateFrame("Button", nil, flyout)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetPoint("TOPLEFT", 1, -1); b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.edges = addEdges(b, 1, 1, 1, 0.2, "OVERLAY")
    b.count = b:CreateFontString(nil, "OVERLAY")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.label = b:CreateFontString(nil, "OVERLAY")
    b.label:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self)
        self.edges:SetColor(ar, ag, ab, 1)
        tooltipBesideFlyout(self)
        if self.itemID and GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID)
        else
            GameTooltip:AddLine("Auto")
            GameTooltip:AddLine("Back to your " .. (self.orderText or "strongest first") .. " setting", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.edges:SetColor(self.current and ar or 1, self.current and ag or 1, self.current and ab or 1, self.current and 1 or 0.2)
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function(self)
        setOverride(flyout.key, self.itemID) -- nil = Auto
        GameTooltip:Hide()
        flyout:Hide()
    end)
    flyout.buttons[i] = b
    return b
end

-- Tooltip next to the open list, on the side with room: right/left of a vertical list,
-- above/below a horizontal one. Returns false when no list is open for this owner.
-- If the bar icon's tooltip is showing, show it again so it picks the right spot
-- (beside the list while it's open, above the icon otherwise)
local function refreshOwnerTooltip(owner)
    if owner and GameTooltip:IsOwned(owner) then
        local onEnter = owner:GetScript("OnEnter")
        if onEnter then onEnter(owner) end
    end
end

tooltipBesideFlyout = function(owner)
    if not (flyout and flyout:IsShown()) then return false end
    if owner ~= flyout.owner and owner:GetParent() ~= flyout then return false end
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    local scale = flyout:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if flyout.vertical then -- list runs sideways (vertical bar): tooltip above, or below near the top
        if (flyout:GetTop() or 0) * scale + 250 < screenH then
            GameTooltip:SetPoint("BOTTOMLEFT", flyout, "TOPLEFT", 0, 6)
        else
            GameTooltip:SetPoint("TOPLEFT", flyout, "BOTTOMLEFT", 0, -6)
        end
    else -- list runs upwards: tooltip to the right, or to the left near the right edge
        if (flyout:GetRight() or 0) * scale + 320 < screenW then
            GameTooltip:SetPoint("BOTTOMLEFT", flyout, "BOTTOMRIGHT", 6, 0)
        else
            GameTooltip:SetPoint("BOTTOMRIGHT", flyout, "BOTTOMLEFT", -6, 0)
        end
    end
    return true
end

openFlyout = function(slot, key)
    if not flyout then buildFlyout() end
    if flyout:IsShown() and flyout.owner == slot then -- right-click again closes
        flyout:Hide()
        refreshOwnerTooltip(slot)
        return
    end
    local ar, ag, ab = accent()
    local db = barDB()
    local size = math.max(24, db.iconSize or BAR_SIZE)
    local gap = 4
    local ov = ProvisionsCharDB and ProvisionsCharDB.override and ProvisionsCharDB.override[key]

    -- entries: Auto first, then every candidate, strongest first
    local entries = { { id = nil } }
    local list = {}
    for _, c in pairs(lastCands[key] or {}) do list[#list + 1] = c end
    table.sort(list, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
    for _, c in ipairs(list) do entries[#entries + 1] = c end

    local vertical = (db.grow == "UP" or db.grow == "DOWN") -- vertical bar: list opens to the side
    for i, e in ipairs(entries) do
        local b = flyoutButton(i)
        b:SetSize(size, size)
        b:ClearAllPoints()
        local off = gap + (i - 1) * (size + gap)
        if vertical then b:SetPoint("LEFT", flyout, "LEFT", off, 0)
        else b:SetPoint("BOTTOM", flyout, "BOTTOM", 0, off) end
        b.itemID = e.id
        b.count:SetFont(flyout.font, math.max(9, math.floor(size * 0.38)), "OUTLINE")
        b.label:SetFont(flyout.font, math.max(9, math.floor(size * 0.34)), "OUTLINE")
        if e.id then
            b.tex:SetTexture(itemIcon(e.id) or MACRO_ICON) -- also replaces the Auto button's solid fill
            b.count:SetText(countOf and countOf(e.id) or "")
            b.label:SetText("")
        else
            b.tex:SetColorTexture(0.075, 0.113, 0.141, 1)
            b.count:SetText("")
            b.label:SetText("Auto")
            b.label:SetTextColor(ar, ag, ab, 1)
        end
        b.current = (e.id == ov) -- nil == nil highlights Auto when there's no pick
        b.orderText = (getOrder(GROUP_OF[key]) == "low") and "weakest first" or "strongest first"
        if b.current then b.edges:SetColor(ar, ag, ab, 1) else b.edges:SetColor(1, 1, 1, 0.2) end
        b:Show()
    end
    for i = #entries + 1, #flyout.buttons do flyout.buttons[i]:Hide() end

    local length = gap + #entries * (size + gap)
    flyout:ClearAllPoints()
    if vertical then
        flyout:SetSize(length, size + gap * 2)
        flyout:SetPoint("LEFT", slot, "RIGHT", 4, 0)
    else
        flyout:SetSize(size + gap * 2, length)
        flyout:SetPoint("BOTTOM", slot, "TOP", 0, 4)
    end
    flyout.owner, flyout.key, flyout.vertical = slot, key, vertical
    flyout:Show()
    refreshOwnerTooltip(slot) -- move the icon's tooltip out of the list's way right away
end

unlockBar = function()
    local db = barDB()
    if not db.locked then return end
    if not barChangeAllowed() then return end
    db.locked = false
    GameTooltip:Hide()
    safeBarRefresh()
    if panelRefresh then panelRefresh() end
    print("|cff33ff99Provisions|r bar unlocked - drag it, then click the key icon to lock it again")
end

-- Click-through bars ignore the mouse; while Alt is held they accept clicks so Alt + click can unlock them
local altFrame = CreateFrame("Frame")
altFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
altFrame:SetScript("OnEvent", function(_, _, key)
    if key and not key:find("ALT") then return end -- Shift/Ctrl presses: nothing to do
    if not bar or not bar:IsShown() then return end
    local db = barDB()
    if not (db.locked and db.clickThrough) then return end
    if bar.sslots and InCombatLockdown() then return end -- protected buttons can't change in combat
    local alt = IsAltKeyDown() and true or false
    bar:EnableMouse(alt)
    for _, set in ipairs({ bar.slots, bar.sslots or {} }) do
        for _, slot in ipairs(set) do if slot:IsShown() then slot:EnableMouse(alt) end end
    end
end)

local function resetBar()
    if not barChangeAllowed() then return end
    local db = barDB()
    db.point, db.pos = nil, nil
    if bar then bar:ClearAllPoints(); bar:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
    print("|cff33ff99Provisions|r item bar moved back to the centre of the screen")
end


---------------------------------------------------------------- shared vs per-character settings
-- ProvisionsDB (all characters): options, item bar look/position, settings tab, minimap button.
-- ProvisionsCharDB (this character): item order, which items the bar shows, right-click picks.
local SHARED_KEYS = { "splitFood", "conjuredFirst", "skipBuffFood", "tab", "subTab" }
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end
local migrateFrame = CreateFrame("Frame")
migrateFrame:RegisterEvent("ADDON_LOADED")
migrateFrame:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    ProvisionsDB = ProvisionsDB or {}
    ProvisionsCharDB = ProvisionsCharDB or {}
    local g, c = ProvisionsDB, ProvisionsCharDB
    -- once per account: the first character loaded with this version donates its settings as the shared ones
    if not g.hybrid then
        if c.bar then g.bar = deepCopy(c.bar) end
        if g.bar then g.bar.items = nil end
        for _, key in ipairs(SHARED_KEYS) do
            if c[key] ~= nil then g[key] = c[key] end
        end
        g.order, g.override = nil, nil -- leftovers from very old versions
        g.hybrid = true
    end
    -- every character: keep only its own specifics
    if c.bar then
        if c.bar.items and not c.barItems then c.barItems = c.bar.items end
        c.bar = nil
    end
    for _, key in ipairs(SHARED_KEYS) do c[key] = nil end
    c.fresh = nil
end)

---------------------------------------------------------------- minimap button (bread)
local BREAD_ITEM = 4540 -- Tough Hunk of Bread, used for its icon
local function breadIcon()
    local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    local icon = instant and select(5, instant(BREAD_ITEM))
    return icon or "Interface\\Icons\\INV_Misc_Food_11"
end

local function setupMinimap()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not DBIcon or DBIcon:IsRegistered("Provisions") then return end
    ProvisionsDB = ProvisionsDB or {}
    ProvisionsDB.minimap = ProvisionsDB.minimap or {}
    local obj = LDB:NewDataObject("Provisions", {
        type = "launcher",
        text = "Provisions",
        icon = breadIcon(),
        OnClick = function(_, button)
            if button == "LeftButton" then togglePanel() end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("Provisions")
            tt:AddLine("|cffffffffClick|r to open settings", 0.7, 0.7, 0.7)
            tt:AddLine("|cffffffffDrag|r to move this button", 0.7, 0.7, 0.7)
        end,
    })
    DBIcon:Register("Provisions", obj, ProvisionsDB.minimap)
end

local function toggleMinimap()
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not DBIcon then return end
    ProvisionsDB.minimap.hide = not ProvisionsDB.minimap.hide
    if ProvisionsDB.minimap.hide then DBIcon:Hide("Provisions") else DBIcon:Show("Provisions") end
    print("|cff33ff99Provisions|r minimap button " .. (ProvisionsDB.minimap.hide and "hidden (/prov minimap to show)" or "shown"))
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    local ok, err = pcall(setupMinimap)
    if not ok then print("|cff33ff99Provisions|r minimap button failed: " .. tostring(err)) end
end)

---------------------------------------------------------------- factory reset (shared + this character)
StaticPopupDialogs["PROVISIONS_RESET"] = {
    text = "Reset Provisions to the first-install defaults?\n\nOptions and the item bar (position, size, lock...) are shared, so they reset for ALL characters. Item order, bar items and right-click picks reset for this character only.\n\nThis reloads your UI.",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function()
        local old = ProvisionsDB or {}
        ProvisionsDB = { minimap = old.minimap, hybrid = true } -- keep the minimap button where it is
        ProvisionsCharDB = {}
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_PROVISIONS1 = "/prov"
SLASH_PROVISIONS2 = "/provisions"
SLASH_PROVISIONS3 = "/eatdrink" -- old command still works
SlashCmdList.PROVISIONS = function(input)
    local P = "|cff33ff99Provisions|r "
    local cmd, group, mode = (input or ""):lower():match("^(%S*)%s*(%S*)%s*(%S*)")
    if cmd == "" then togglePanel(); return end
    if cmd == "minimap" then toggleMinimap(); return end
    if cmd == "resetbar" then resetBar(); return end
    if cmd == "reset" then
        if InCombatLockdown() then print(P .. "reset is only possible outside combat"); return end
        StaticPopup_Show("PROVISIONS_RESET")
        return
    end
    if cmd == "debug" then
        -- one line per item in your bags: what Provisions thinks it is
        print(P .. "items in your bags (level " .. UnitLevel("player") .. ", mana " .. tostring(usesMana()) .. "):")
        local seen = {}
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            for slot = 1, (bagSlots(bag) or 0) do
                local id = bagItem(bag, slot)
                if id and not seen[id] then
                    seen[id] = true
                    local name, _, _, _, minLevel, _, _, _, _, _, _, classID, subClassID = GetItemInfo(id)
                    local c = infoCache[id]
                    local state
                    if c then
                        state = string.format("%s h%d m%d%s%s", c.kind, c.health or 0, c.mana or 0,
                            c.conjured and " conjured" or "", c.buff and " buff" or "")
                    elseif c == false then state = "not relevant"
                    elseif gaveUp[id] then state = "text never loaded"
                    elseif pendingSince[id] then state = "waiting for text"
                    else state = "not checked" end
                    local hasUse = false
                    for _, line in ipairs(tooltipLines(bag, slot)) do if line:find("^Use:") then hasUse = true end end
                    local usable = (not IsUsableItem) or IsUsableItem(id)
                    if classID == 0 or c then
                        print(string.format("  %s [%d] class %s/%s lvl %s: %s, Use-line %s, usable %s",
                            name or "?", id, tostring(classID), tostring(subClassID), tostring(minLevel),
                            state, hasUse and "yes" or "NO", tostring(usable)))
                    end
                end
            end
        end
        return
    end
    if cmd == "order" then
        local valid = { food = true, potions = true, bandage = true, healthstone = true }
        if valid[group] and (mode == "high" or mode == "low") then
            setOrder(group, mode)
            print(P .. group .. ": " .. (mode == "low" and "weakest first" or "strongest first"))
        else
            print(P .. "usage: /prov order <food|potions|bandage|healthstone> <high|low>")
        end
        print(P .. "current order: food " .. getOrder("food") .. ", potions " .. getOrder("potions")
            .. ", bandage " .. getOrder("bandage") .. ", healthstone " .. getOrder("healthstone"))
    elseif cmd ~= "info" then
        print(P .. "/prov = settings window, /prov info = current picks, /prov minimap = show/hide button, /prov resetbar = move the item bar back to the centre, /prov reset = factory reset (shared settings + this character), /prov order <group> <high|low>")
        return
    end
    update()
    local function describe(p, what)
        if not p then return "none" end
        local name = GetItemInfo(p.id) or ("item " .. p.id)
        return string.format("%s (%d %s, %d in bags)", name, p.v, what, p.c)
    end
    print(P .. "food: " .. describe(lastPick.food, "health"))
    print(P .. "drink: " .. describe(lastPick.drink, "mana"))
    print(P .. "healing potion: " .. describe(lastPick.hpot, "health"))
    print(P .. "mana potion: " .. describe(lastPick.mpot, "mana"))
    print(P .. "bandage: " .. describe(lastPick.bandage, "healing"))
    print(P .. "healthstone: " .. describe(lastPick.stone, "health"))
end
