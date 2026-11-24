-- Provisions raid bars: your own lists of raid consumables, one list per character and bar.
--   Raid bar     lasting raid buffs: flasks, elixirs, buff food, juju, world buffs, scrolls, weapon oils and stones
--   Raid stims   short-use items for certain fights: protection potions, Free Action, Stoneshield...
-- (Demonic and Dark Runes are on the main item bar: Rune macro.)
--   * Drag an item from your bags onto a bar to add it (or /prov raid add, /prov stims add <item link or ID>).
--   * Left-click uses it. Weapon oils, stones and poisons go straight onto your main hand (or off hand).
--   * Items you've run out of stay on the bar, greyed out with 0, as a restock reminder.
--   * Glow: pulsing orange when you carry the item but its buff isn't on you (in raids),
--     a steady green frame and the time left while the buff is up.
--   * Right-click an icon for its options (glow on/off, main or off hand, move, presets, remove).
-- Which buff an item gives is read from the game (the item's spell), so it works in any client language.
-- Items Provisions doesn't know yet are learned the first time you use them.

local ADDON, NS = ...
NS = NS or {}
local R = {}
NS.raid = R

local P = "|cff33ff99Provisions|r "
local function out(msg) (NS.print or print)(P .. msg) end

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetItemSpell = (C_Item and C_Item.GetItemSpell) or _G.GetItemSpell
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local getCount = (C_Item and C_Item.GetItemCount) or _G.GetItemCount
local getItemCooldown = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown
local requestItem = C_Item and C_Item.RequestLoadItemDataByID
local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return GetSpellInfo and (GetSpellInfo(id))
end

---------------------------------------------------------------- what the items are
-- A head start, so the glow works before you've used an item once. A wrong or missing ID here is harmless:
-- Provisions also learns from what actually happens when you use an item.
--   buff    lasting buff (raid bar)
--   stim    short buff for certain fights (raid stims bar)
--   weapon  goes on a weapon (oil, sharpening stone, weightstone, poison)
--   none    instant, nothing to watch (runes, potions: these belong on the main item bar)
local KNOWN = {}
local function known(kind, ...) for i = 1, select("#", ...) do KNOWN[(select(i, ...))] = kind end end
known("buff",
    13510, 13511, 13512, 13513, 13506,                                     -- flasks
    13452, 9206, 21546, 13454, 9264, 17708, 3825, 13445, 9179, 20007,      -- elixirs
    20004, 3826, 13453, 9187, 9088, 9155, 8951, 9224, 6373,
    20079, 20081, 20080,                                                   -- Zanza
    12451, 12460, 12455, 12457, 12450, 12458,                              -- juju
    12820, 8412, 8410, 8411, 8423, 8424, 21151, 18269, 18284,              -- Blasted Lands, firewater, drinks
    10310, 10309, 10305, 10306, 10307, 10308,                              -- scrolls IV
    13810, 13813)                                                          -- Blessed Sunfruit (+ juice)
known("stim",
    13457, 13456, 13458, 13459, 13461, 13460,                              -- greater protection potions
    6049, 6050, 6052, 6048, 6051,                                          -- protection potions
    5634, 20008, 3387, 13455, 9030, 12459, 13442, 2459)                    -- Free/Living Action, LIP, Stoneshield...
known("weapon",
    20749, 20748, 20750, 20747, 20746, 20745, 20744, 23123, 3824, 3829,    -- oils
    18262, 12404, 12643, 23122, 7964, 7965, 2871, 3241, 2863, 3240, 2862, 3239, -- stones
    8928, 8927, 8926, 20844, 8985, 8984, 10922, 9186, 3776)                -- poisons
local RUNES = { [12662] = true, [20520] = true } -- Demonic Rune, Dark Rune: main item bar
known("none", 12662, 20520, 13446, 13444)

---------------------------------------------------------------- presets
-- Ready-made lists for both bars. Loading one adds what you don't have yet (or replaces your lists).
-- Your own options per item (glow, hand) are kept.
local PRESETS = {
    {
        key = "protpaladin", name = "Protection Paladin", short = "Prot Paladin",
        note = "Tank: armor, stamina and avoidance, threat from strength and spell damage, mana for Holy Shield and Consecration.",
        raid = {
            13510, -- Flask of the Titans
            13445, -- Elixir of Superior Defense
            3825,  -- Elixir of Fortitude
            13452, -- Elixir of the Mongoose
            13454, -- Greater Arcane Elixir
            20007, -- Mageblood Potion
            21023, -- Dirge's Kickin' Chimaerok Chops
            21151, -- Rumsey Rum Black Label
            20079, -- Spirit of Zanza
            12451, -- Juju Power (does not stack with Elixir of Giants, so Giants is left out)
            12820, -- Winterfall Firewater
            8412,  -- Ground Scorpok Assay
            8410,  -- R.O.I.D.S.
            9088,  -- Gift of Arthas
            10305, -- Scroll of Protection IV
            10310, -- Scroll of Strength IV
            20749, -- Brilliant Wizard Oil (main hand)
        },
        stims = {
            13455, -- Greater Stoneshield Potion
            5634,  -- Free Action Potion
            13457, -- Greater Fire Protection Potion
            13459, -- Greater Shadow Protection Potion
            13458, -- Greater Nature Protection Potion
            13456, -- Greater Frost Protection Potion
            13461, -- Greater Arcane Protection Potion
        },
    },
}
local PRESET_BY_KEY = {}
for _, p in ipairs(PRESETS) do PRESET_BY_KEY[p.key] = p end

---------------------------------------------------------------- learned (all characters)
local function learned()
    ProvisionsDB = ProvisionsDB or {}
    ProvisionsDB.raidLearned = ProvisionsDB.raidLearned or {}
    local l = ProvisionsDB.raidLearned
    l.buff = l.buff or {}     -- [itemID] = true (gives a buff) / false (doesn't)
    l.weapon = l.weapon or {} -- [itemID] = true (goes on a weapon)
    return l
end

local function isWeapon(id) return learned().weapon[id] or KNOWN[id] == "weapon" end
local function isWellFed(id) -- buff food from the shipped food table (flag w)
    local flags = NS.ITEMS and NS.ITEMS:match("\n" .. id .. "=f,%d*,%d*,(%a*)")
    return flags and flags:find("w") and true or false
end
-- "weapon", "buff", "none" (instant, nothing to watch) or "unknown" (not used yet)
local function kindOf(id)
    if isWeapon(id) then return "weapon" end
    local l = learned().buff[id]
    if l == true then return "buff" elseif l == false then return "none" end
    local k = KNOWN[id]
    if k == "none" then return "none" end
    if k == "buff" or k == "stim" or isWellFed(id) then return "buff" end
    return "unknown"
end

local function inRaid()
    if IsInRaid and IsInRaid() then return true end
    local _, kind = IsInInstance()
    return kind == "raid"
end

---------------------------------------------------------------- is the buff on you?
-- WoW Forever's client keeps combat data "secret": during combat addons may not read your auras (the game
-- raises an error, once per try). So Provisions reads them only while that's allowed and keeps the last
-- reading through the fight. Items you use from your bags in combat count as active until the fight ends.
local auraBySpell, auraByName = {}, {}
local aurasLocked = false   -- true while the game keeps auras secret (combat)
local usedInFight = {}      -- [item spellID] = true: used during the current lockout
local isSecret = _G.issecretvalue or function() return false end

local function aurasSecretNow()
    if InCombatLockdown() then return true end
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, res = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and res == true then return true end
    end
    return false
end

local function readAuras(bySpell, byName)
    for i = 1, 40 do
        local name, spellId, expires
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not a then break end
            name, spellId, expires = a.name, a.spellId, a.expirationTime
        else
            local n, _, _, _, _, exp, _, _, _, sid = UnitBuff("player", i)
            if not n then break end
            name, spellId, expires = n, sid, exp
        end
        if isSecret(name) or isSecret(spellId) or isSecret(expires) then error("secret") end
        expires = expires or 0
        if spellId then bySpell[spellId] = expires end
        if name and byName[name] == nil then byName[name] = expires end
    end
end

local function scanAuras()
    if aurasSecretNow() then aurasLocked = true; return end
    local bySpell, byName = {}, {}
    if pcall(readAuras, bySpell, byName) then
        auraBySpell, auraByName = bySpell, byName
        aurasLocked = false
        wipe(usedInFight)
    else
        aurasLocked = true -- keep the last good reading
    end
end

local wellFedName
local weaponCache = {} -- [slot] = { active, expires }: last good reading
local function weaponEnchant(slot) -- active, expires (GetTime() based)
    if not GetWeaponEnchantInfo then return false end
    if not aurasLocked then
        local ok, r, n = pcall(function()
            local t = { GetWeaponEnchantInfo() }
            return t, select("#", GetWeaponEnchantInfo())
        end)
        if ok then
            local has, ms
            if slot == 17 then
                if n >= 8 then has, ms = r[5], r[6] else has, ms = r[4], r[5] end -- newer clients add enchant IDs
            else
                has, ms = r[1], r[2]
            end
            if not (isSecret(has) or isSecret(ms)) then
                if has then weaponCache[slot] = { true, ms and (GetTime() + ms / 1000) or 0 }
                else weaponCache[slot] = { false } end
            end
        end
    end
    local c = weaponCache[slot]
    if not c then return nil end
    if c[1] and c[2] and c[2] > 0 and c[2] < GetTime() then return false end -- ran out during the fight
    return c[1], c[2]
end

-- active (true/false/nil = can't tell), expires (0 = no timer). hand: 16 main, 17 off hand (weapon items)
local function buffState(id, hand)
    local kind = kindOf(id)
    if kind == "weapon" then return weaponEnchant(hand or 16) end
    if kind == "none" then return nil end
    local sName, sID = nil, nil
    if GetItemSpell then sName, sID = GetItemSpell(id) end
    if aurasLocked and sID and usedInFight[sID] then return true, 0 end -- used this fight: count it as up
    local exp = (sID and auraBySpell[sID]) or (sName and auraByName[sName])
    if exp == nil and isWellFed(id) then
        wellFedName = wellFedName or spellName(19705) or "Well Fed"
        exp = auraByName[wellFedName]
    end
    if exp ~= nil and exp > 0 and exp < GetTime() then exp = nil end -- ran out since the last reading
    if exp ~= nil then
        if kind == "unknown" and not aurasLocked then learned().buff[id] = true end -- seen its buff: watch it from now on
        return true, exp
    end
    if kind == "unknown" then return nil end
    return false
end

-- an item spell was cast while auras are secret: remember it so its icon counts as active
local function noteUsedInFight(spellID)
    if aurasLocked and spellID and not isSecret(spellID) then usedInFight[spellID] = true end
end

---------------------------------------------------------------- look (shared with the rest of Provisions)
local BAR_GAP = 4
local MISSING = { 1, 0.55, 0.15 } -- pulsing orange: carry it, buff not on you
local function iconSize() return (NS.barDB and NS.barDB().iconSize) or 32 end
local function fontPath() return (NS.fontPath and NS.fontPath()) or STANDARD_TEXT_FONT end
local function accent() if NS.accent then return NS.accent() end return 0.05, 0.82, 0.62 end
local function addEdges(frame, r, g, b, a, layer)
    if NS.addEdges then return NS.addEdges(frame, r, g, b, a, layer) end
    local e = {}; function e:SetColor() end; return e
end
local function itemIcon(id)
    return id and GetItemInfoInstant and select(5, GetItemInfoInstant(id)) or 134400
end
local function itemName(id) return (GetItemInfo and GetItemInfo(id)) or ("item " .. id) end
local function fmtTime(left)
    if left >= 3600 then return math.floor(left / 3600 + 0.5) .. "h" end
    if left >= 60 then return math.floor(left / 60 + 0.5) .. "m" end
    return math.floor(left) .. "s"
end
local function changeAllowed(label, what)
    if InCombatLockdown() then
        out("the " .. label .. " can't " .. (what or "change") .. " during combat - try again after the fight")
        return false
    end
    return true
end
local GROW_ANCHOR = { RIGHT = "LEFT", LEFT = "RIGHT", UP = "BOTTOM", DOWN = "TOP" }

---------------------------------------------------------------- right-click menu (shared by both bars)
local menu
local function buildMenu()
    local FONT = fontPath()
    local ar, ag, ab = accent()
    menu = CreateFrame("Frame", "ProvisionsRaidMenu", UIParent)
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    tinsert(UISpecialFrames, "ProvisionsRaidMenu") -- Escape closes it
    local bg = menu:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.077, 0.068, 0.058, 0.97)
    addEdges(menu, 1, 1, 1, 0.2)
    menu.title = menu:CreateFontString(nil, "OVERLAY")
    menu.title:SetFont(FONT, 12, "")
    menu.title:SetTextColor(ar, ag, ab, 1)
    menu.title:SetPoint("TOPLEFT", 10, -9)
    menu.title:SetJustifyH("LEFT")
    menu.rows = {}
    -- closes when the mouse has been away from it and its icon for a moment
    local away, tick = 0, 0
    menu:SetScript("OnUpdate", function(self, dt)
        tick = tick + dt
        if tick < 0.1 then return end
        local step = tick; tick = 0
        local over = self:IsMouseOver() or (self.owner and self.owner:IsVisible() and self.owner:IsMouseOver())
        if over then away = 0 else away = away + step; if away > 1.2 then self:Hide() end end
    end)
    menu:SetScript("OnHide", function() away, tick = 0, 0 end)
    menu.font = FONT
    menu:Hide()
end

local function menuRow(i)
    local r = menu.rows[i]
    if r then return r end
    local ar, ag, ab = accent()
    r = CreateFrame("Button", nil, menu)
    r:SetHeight(20)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(ar, ag, ab, 0.18)
    r.hl:Hide()
    r.text = r:CreateFontString(nil, "OVERLAY")
    r.text:SetFont(menu.font, 12, "")
    r.text:SetPoint("LEFT", 10, 0)
    r.text:SetJustifyH("LEFT")
    r:SetScript("OnEnter", function(self) self.hl:Show() end)
    r:SetScript("OnLeave", function(self) self.hl:Hide() end)
    r:SetScript("OnClick", function(self)
        menu:Hide()
        if self.fn then self.fn() end
    end)
    menu.rows[i] = r
    return r
end

local function showMenu(owner, title, entries, vertical)
    if not menu then buildMenu() end
    if menu:IsShown() and menu.owner == owner then menu:Hide(); return end
    GameTooltip:Hide()
    menu.title:SetText(title)
    local w = math.max(menu.title:GetStringWidth() + 20, 150)
    for i, e in ipairs(entries) do
        local r = menuRow(i)
        r.text:SetText(e[1])
        r.fn = e[2]
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", menu, "TOPLEFT", 0, -(26 + (i - 1) * 20))
        r:SetPoint("RIGHT", menu, "RIGHT", 0, 0)
        w = math.max(w, r.text:GetStringWidth() + 24)
        r:Show()
    end
    for i = #entries + 1, #menu.rows do menu.rows[i]:Hide() end
    menu:SetSize(w, 26 + #entries * 20 + 6)
    menu:ClearAllPoints()
    if vertical then menu:SetPoint("LEFT", owner, "RIGHT", 6, 0)
    else menu:SetPoint("BOTTOM", owner, "TOP", 0, 6) end
    menu.owner = owner
    menu:Show()
end

local function presetMenu(owner, vertical)
    local entries = {}
    for _, p in ipairs(PRESETS) do
        entries[#entries + 1] = { p.name, function() R.askPreset(p.key) end }
    end
    showMenu(owner, "Load a preset (both bars)", entries, vertical)
end

---------------------------------------------------------------- one bar
local BARS, BAR_LIST = {}, {}

local function newBar(cfg)
    local B = { cfg = cfg }
    local bar
    local slots = {}
    local layoutPending = false
    local errorShown = false
    local label = cfg.label

    function B.db()
        ProvisionsDB = ProvisionsDB or {}
        ProvisionsDB[cfg.dbKey] = ProvisionsDB[cfg.dbKey] or {}
        local b = ProvisionsDB[cfg.dbKey]
        if b.show == nil then b.show = "always" end   -- always | raid | hide
        if b.locked == nil then b.locked = false end  -- first time: unlocked, so it can be placed
        if b.grow == nil then b.grow = "RIGHT" end
        if b.glow == nil then                         -- both | missing | active | off
            if b.remind == "off" then b.glow = "active" else b.glow = cfg.glow end -- v1.7 test setting
        end
        b.remind = nil
        return b
    end
    local db = B.db
    function B.char()
        ProvisionsCharDB = ProvisionsCharDB or {}
        ProvisionsCharDB[cfg.charKey] = ProvisionsCharDB[cfg.charKey] or {}
        local c = ProvisionsCharDB[cfg.charKey]
        c.items = c.items or {}
        c.opts = c.opts or {}
        return c
    end
    local charDB = B.char
    local function itemOpts(id)
        local c = charDB()
        c.opts[id] = c.opts[id] or {}
        return c.opts[id]
    end
    local function reminds(id) -- missing-glow for this item
        local o = charDB().opts[id]
        if o and o.remind ~= nil then return o.remind end
        return true
    end
    local function weaponSlot(id) local o = charDB().opts[id]; return (o and o.offhand) and 17 or 16 end
    B.weaponSlot, B.reminds = weaponSlot, reminds
    local function vertical() return db().grow == "UP" or db().grow == "DOWN" end

    local function frozen() return InCombatLockdown() end -- the bar holds protected buttons

    local function applyAnchor()
        local b = db()
        if not b.pos or frozen() then return end
        bar:ClearAllPoints()
        bar:SetPoint(GROW_ANCHOR[b.grow] or "LEFT", UIParent, "BOTTOMLEFT", b.pos[1], b.pos[2])
    end
    local function savePos()
        local b = db()
        local anchor = GROW_ANCHOR[b.grow] or "LEFT"
        local l, r, t, bt = bar:GetLeft(), bar:GetRight(), bar:GetTop(), bar:GetBottom()
        if not (l and r and t and bt) then return end
        local x, y
        if anchor == "LEFT" then x, y = l, (t + bt) / 2
        elseif anchor == "RIGHT" then x, y = r, (t + bt) / 2
        elseif anchor == "BOTTOM" then x, y = (l + r) / 2, bt
        else x, y = (l + r) / 2, t end
        b.pos = { x, y }
    end

    function B.addItem(id, quiet)
        id = tonumber(id)
        if not id then return end
        if not changeAllowed(label, "take new items") then return end
        if RUNES[id] then out(itemName(id) .. " is on the main item bar (Rune macro), so it isn't added here"); return end
        local c = charDB()
        for _, have in ipairs(c.items) do
            if have == id then if not quiet then out(itemName(id) .. " is already on the " .. label) end return end
        end
        c.items[#c.items + 1] = id
        if requestItem then pcall(requestItem, id) end
        if not quiet then
            out("added " .. itemName(id) .. " to the " .. label)
            if cfg.key == "raid" and KNOWN[id] == "stim" then out("tip: short-use items like this one fit the raid stims bar (/prov stims add)") end
        end
        R.refreshAll()
    end
    local function removeItem(id)
        if not changeAllowed(label) then return end
        local c = charDB()
        for i, have in ipairs(c.items) do
            if have == id then table.remove(c.items, i); break end
        end
        c.opts[id] = nil
        R.refreshAll()
    end
    local function moveItem(id, step)
        if not changeAllowed(label) then return end
        local items = charDB().items
        for i, have in ipairs(items) do
            if have == id then
                local j = i + step
                if j >= 1 and j <= #items then items[i], items[j] = items[j], items[i] end
                break
            end
        end
        R.refreshAll()
    end
    -- move an item to the other bar
    local function sendTo(other, id)
        if not changeAllowed(label) then return end
        local o = charDB().opts[id]
        removeItem(id)
        other.addItem(id, true)
        if o then other.char().opts[id] = o end
        out(itemName(id) .. " moved to the " .. other.cfg.label)
        R.refreshAll()
    end

    -- an item dropped from the cursor onto the bar
    local function takeCursorItem()
        local kind, id = GetCursorInfo()
        if kind ~= "item" or not id then return false end
        ClearCursor()
        B.addItem(id)
        return true
    end

    local function unlock()
        local b = db()
        if not b.locked or not changeAllowed(label, "unlock") then return end
        b.locked = false
        GameTooltip:Hide()
        R.refreshAll()
        if NS.panelRefresh then NS.panelRefresh() end
        out(label .. " unlocked - drag it, then click the key icon to lock it again")
    end

    local menuOpen -- right-click on an icon, set below

    local function buildBar()
        local FONT = fontPath()
        local ar, ag, ab = accent()
        bar = CreateFrame("Frame", cfg.frame, UIParent)
        bar:SetFrameStrata("MEDIUM")
        bar:SetClampedToScreen(true)
        bar:SetMovable(true)
        bar:EnableMouse(true)
        bar:RegisterForDrag("LeftButton")
        bar.startMove = function()
            if db().locked or frozen() then return end
            bar:StartMoving()
        end
        bar.stopMove = function()
            bar:StopMovingOrSizing()
            savePos()
            applyAnchor()
        end
        bar:SetScript("OnDragStart", bar.startMove)
        bar:SetScript("OnDragStop", bar.stopMove)
        bar:SetScript("OnReceiveDrag", takeCursorItem)
        bar:SetScript("OnMouseUp", function(_, button)
            if takeCursorItem() then return end
            if button == "LeftButton" and IsAltKeyDown() then unlock() end
        end)
        if db().pos then applyAnchor() else bar:SetPoint("CENTER", UIParent, "CENTER", 0, cfg.y) end

        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.077, 0.068, 0.058, 0.85)
        bar.edges = addEdges(bar, 1, 1, 1, 0.15)
        bar.accent = { ar, ag, ab }

        bar.dragLabel = bar:CreateFontString(nil, "OVERLAY")
        bar.dragLabel:SetFont(FONT, 11, "OUTLINE")
        bar.dragLabel:SetTextColor(ar, ag, ab, 1)
        bar.dragLabel:SetText(label .. " - drag to move")

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
        bar.lockBtn = miniButton("Interface\\Icons\\INV_Misc_Key_03", "Lock the " .. label .. " in place", function()
            if not changeAllowed(label, "lock") then return end
            db().locked = true
            GameTooltip:Hide()
            R.refreshAll()
            if NS.panelRefresh then NS.panelRefresh() end
        end)
        bar.lockBtn:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, 3)
        bar.gearBtn = miniButton("Interface\\Icons\\INV_Misc_Gear_01", "Provisions settings", function()
            GameTooltip:Hide()
            if NS.openSettings then NS.openSettings(4, cfg.sub) end
        end)
        bar.gearBtn:SetPoint("RIGHT", bar.lockBtn, "LEFT", -4, 0)
        bar.dragLabel:SetPoint("RIGHT", bar.gearBtn, "LEFT", -6, 0)

        -- drop target at the end of the bar: shown while unlocked or while the list is empty
        local add = CreateFrame("Button", nil, bar)
        add:EnableMouse(true)
        add:RegisterForDrag("LeftButton")
        add:SetScript("OnDragStart", bar.startMove)
        add:SetScript("OnDragStop", bar.stopMove)
        add.bg = add:CreateTexture(nil, "ARTWORK")
        add.bg:SetPoint("TOPLEFT", 1, -1); add.bg:SetPoint("BOTTOMRIGHT", -1, 1)
        add.bg:SetColorTexture(0.075, 0.113, 0.141, 1)
        add.edges = addEdges(add, 1, 1, 1, 0.2, "OVERLAY")
        add.plus = add:CreateFontString(nil, "OVERLAY")
        add.plus:SetFont(FONT, 18, "OUTLINE")
        add.plus:SetPoint("CENTER", 0, 1)
        add.plus:SetTextColor(ar, ag, ab, 1)
        add.plus:SetText("+")
        add:SetScript("OnReceiveDrag", takeCursorItem)
        add:SetScript("OnMouseUp", function(self, button)
            if takeCursorItem() then return end
            if button == "RightButton" then presetMenu(self, vertical())
            elseif button == "LeftButton" and IsAltKeyDown() then unlock() end
        end)
        add:SetScript("OnEnter", function(self)
            self.edges:SetColor(ar, ag, ab, 1)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(cfg.addTitle)
            GameTooltip:AddLine("Drag an item from your bags and drop it here.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("Or type /prov " .. cfg.key .. " add and shift-click the item.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("Right-click: load a preset (e.g. Protection Paladin).", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        add:SetScript("OnLeave", function(self) self.edges:SetColor(1, 1, 1, 0.2); GameTooltip:Hide() end)
        bar.add = add
    end

    local function setGlow(s, state)
        if s.glowState == state then return end
        s.glowState = state
        if not state then
            s.glow.pulse:Stop()
            s.glow:SetAlpha(0)
            return
        end
        local r, g, b
        if state == "missing" then r, g, b = MISSING[1], MISSING[2], MISSING[3] else r, g, b = accent() end
        for _, t in ipairs(s.glow.edges) do t:SetColorTexture(r, g, b, 1) end
        s.glow.halo:SetVertexColor(r, g, b, 1)
        s.glow.wash:SetColorTexture(r, g, b, state == "missing" and 0.35 or 0.15)
        s.glow:SetAlpha(1)
        if state == "missing" then s.glow.pulse:Play() else s.glow.pulse:Stop() end
    end

    local function makeSlot(i)
        local FONT = fontPath()
        local ar, ag, ab = accent()
        local s = CreateFrame("Button", cfg.button .. i, bar, "SecureActionButtonTemplate")
        s:RegisterForClicks("AnyUp")
        s:SetAttribute("useOnKeyDown", false)    -- act on mouse-up like our other handlers
        s:SetAttribute("alt-type1", "macro")     -- Alt + left-click is for unlocking: uses nothing
        s:SetAttribute("alt-macrotext1", "")
        s:EnableMouse(true)
        s:RegisterForDrag("LeftButton")
        s:SetScript("OnDragStart", bar.startMove)
        s:SetScript("OnDragStop", bar.stopMove)
        s:SetScript("OnReceiveDrag", takeCursorItem)

        s.tex = s:CreateTexture(nil, "ARTWORK")
        s.tex:SetPoint("TOPLEFT", 1, -1); s.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        s.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        s.edges = addEdges(s, 1, 1, 1, 0.2, "OVERLAY")

        s.cd = CreateFrame("Cooldown", nil, s, "CooldownFrameTemplate")
        s.cd:SetPoint("TOPLEFT", 1, -1); s.cd:SetPoint("BOTTOMRIGHT", -1, 1)
        if s.cd.SetHideCountdownNumbers then s.cd:SetHideCountdownNumbers(true) end

        -- texts sit above the cooldown swipe
        s.over = CreateFrame("Frame", nil, s)
        s.over:SetAllPoints()
        s.over:SetFrameLevel(s.cd:GetFrameLevel() + 2)
        s.count = s.over:CreateFontString(nil, "OVERLAY")
        s.count:SetFont(FONT, 12, "OUTLINE")
        s.count:SetPoint("BOTTOMRIGHT", -2, 2)
        s.time = s.over:CreateFontString(nil, "OVERLAY")
        s.time:SetFont(FONT, 11, "OUTLINE")
        s.time:SetPoint("TOP", 0, -2)

        -- glow: a frame around the icon (a plain child frame, so it may change in combat).
        -- Missing buff: pulsing orange with a soft wash. Buff active: steady accent colour.
        s.glow = CreateFrame("Frame", nil, s)
        s.glow:SetPoint("TOPLEFT", -3, 3); s.glow:SetPoint("BOTTOMRIGHT", 3, -3)
        s.glow:SetFrameLevel(s.over:GetFrameLevel() + 1)
        s.glow.edges = {}
        local function gEdge(p1, p2, w, h)
            local t = s.glow:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(ar, ag, ab, 1)
            t:SetPoint(p1); t:SetPoint(p2)
            if w then t:SetWidth(w) else t:SetHeight(h) end
            s.glow.edges[#s.glow.edges + 1] = t
        end
        gEdge("TOPLEFT", "TOPRIGHT", nil, 3); gEdge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 3)
        gEdge("TOPLEFT", "BOTTOMLEFT", 3); gEdge("TOPRIGHT", "BOTTOMRIGHT", 3)
        -- soft halo around the icon: the game's action button glow, added on top (brightens, never darkens)
        s.glow.halo = s.glow:CreateTexture(nil, "BACKGROUND")
        s.glow.halo:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        s.glow.halo:SetBlendMode("ADD")
        s.glow.halo:SetPoint("CENTER", s, "CENTER", 0, 0)
        s.glow.wash = s.glow:CreateTexture(nil, "ARTWORK")
        s.glow.wash:SetPoint("TOPLEFT", 4, -4); s.glow.wash:SetPoint("BOTTOMRIGHT", -4, 4)
        s.glow.wash:SetBlendMode("ADD")
        local pulse = s.glow:CreateAnimationGroup()
        pulse:SetLooping("BOUNCE")
        local a = pulse:CreateAnimation("Alpha")
        a:SetFromAlpha(1); a:SetToAlpha(0.45); a:SetDuration(0.6)
        if a.SetSmoothing then a:SetSmoothing("IN_OUT") end
        s.glow.pulse = pulse
        s.glow:SetAlpha(0)

        s:SetScript("OnEnter", function(self)
            self.edges:SetColor(ar, ag, ab, 1)
            local id = self.itemID
            if not id then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if GameTooltip.SetItemByID then GameTooltip:SetItemByID(id) else GameTooltip:AddLine(itemName(id)) end
            local b = db()
            local function hint(k, v) GameTooltip:AddDoubleLine(k, v, 1, 1, 1, 0.7, 0.7, 0.7) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Provisions " .. label, ar, ag, ab)
            local kind = kindOf(id)
            local active, exp = buffState(id, weaponSlot(id))
            if kind == "weapon" then
                local hand = weaponSlot(id) == 17 and "Off hand" or "Main hand"
                if active then
                    hint(hand, (exp and exp > 0) and (fmtTime(exp - GetTime()) .. " left") or "enchanted")
                else hint(hand, "nothing applied") end
            elseif kind == "buff" then
                if active then hint("Buff", (exp and exp > 0) and (fmtTime(exp - GetTime()) .. " left") or "active")
                else hint("Buff", "not on you") end
                if not reminds(id) then GameTooltip:AddLine("No orange glow for this item (right-click to switch it on)", 0.6, 0.6, 0.6, true) end
            elseif kind == "unknown" then
                GameTooltip:AddLine("Use it once so Provisions can learn its buff", 0.7, 0.7, 0.7, true)
            end
            if b.locked then
                hint("Left-click", kind == "weapon" and ("apply to " .. (weaponSlot(id) == 17 and "off hand" or "main hand")) or "use")
            else
                hint("Drag", "move the bar (lock it to use items)")
            end
            hint("Right-click", "options")
            if b.locked then hint("Alt + click", "unlock the bar") end
            GameTooltip:Show()
        end)
        s:SetScript("OnLeave", function(self)
            self.edges:SetColor(1, 1, 1, 0.2)
            GameTooltip:Hide()
        end)
        s:HookScript("OnClick", function(self, button)
            if button == "RightButton" then menuOpen(self)
            elseif button == "LeftButton" and IsAltKeyDown() then unlock()
            elseif button == "LeftButton" and self.itemID and SpellIsTargeting and SpellIsTargeting()
                and not isWeapon(self.itemID) and db().locked then
                -- the item wants a target item: it goes on a weapon. Remember that for next time.
                learned().weapon[self.itemID] = true
                out(itemName(self.itemID) .. ": click your weapon this time. From now on Provisions puts it on your weapon for you (right-click the icon to pick main or off hand).")
                R.refreshAll()
            end
        end)
        s:Hide()
        return s
    end

    -- counts, cooldowns, buff timers, glow: allowed at any time, also in combat (auras scanned by the caller)
    local function updateVisuals()
        if not bar or not bar:IsShown() then return end
        local b = db()
        local raid = inRaid()
        local wantMissing = (b.glow == "both" or b.glow == "missing") and raid
        local wantActive = (b.glow == "both" or b.glow == "active")
        local dead = UnitIsDeadOrGhost("player")
        local now = GetTime()
        for _, s in ipairs(slots) do
            local id = s:IsShown() and s.itemID
            if id then
                local count = (getCount and getCount(id)) or 0
                s.count:SetText(count)
                s.tex:SetDesaturated(count == 0)
                s.tex:SetAlpha(count == 0 and 0.4 or 1)
                if count == 0 then s.count:SetTextColor(1, 0.35, 0.3) else s.count:SetTextColor(1, 1, 1) end

                if getItemCooldown then
                    pcall(function() -- cooldowns can be secret in combat too: then the swipe just stays as it is
                        local start, dur, enable = getItemCooldown(id)
                        if isSecret(start) or isSecret(dur) then return end
                        if start and dur and dur > 1.5 and enable ~= 0 and enable ~= false then s.cd:SetCooldown(start, dur)
                        elseif s.cd.Clear then s.cd:Clear() else s.cd:SetCooldown(0, 0) end
                    end)
                end

                local kind = kindOf(id)
                local active, exp = buffState(id, weaponSlot(id))
                if active and exp and exp > 0 then
                    local left = exp - now
                    s.time:SetText(left > 0 and fmtTime(left) or "")
                    if left < 120 then s.time:SetTextColor(1, 0.35, 0.3) else s.time:SetTextColor(1, 0.9, 0.5) end
                else
                    s.time:SetText("")
                end
                local state
                if active and wantActive then
                    state = "active"
                elseif wantMissing and active == false and count > 0 and reminds(id) and not dead
                    and (kind == "buff" or kind == "weapon") then
                    state = "missing"
                end
                setGlow(s, state)
            end
        end
    end
    B.updateVisuals = updateVisuals

    -- which icons, in which order, where: only outside combat (protected buttons)
    local function layout()
        if InCombatLockdown() then layoutPending = true; return end
        layoutPending = false
        local b = db()
        local unlocked = not b.locked
        local visible = b.show == "always" or (b.show == "raid" and (inRaid() or unlocked))
        if not visible then
            if bar then bar:Hide() end
            return
        end
        if not bar then buildBar() end
        local size = iconSize()
        local grow = b.grow or "RIGHT"
        local items = charDB().items
        local n = 0
        local function place(frame)
            frame:ClearAllPoints()
            local off = BAR_GAP + n * (size + BAR_GAP)
            if grow == "LEFT" then frame:SetPoint("RIGHT", bar, "RIGHT", -off, 0)
            elseif grow == "UP" then frame:SetPoint("BOTTOM", bar, "BOTTOM", 0, off)
            elseif grow == "DOWN" then frame:SetPoint("TOP", bar, "TOP", 0, -off)
            else frame:SetPoint("LEFT", bar, "LEFT", off, 0) end
            n = n + 1
        end
        for i, id in ipairs(items) do
            local s = slots[i] or makeSlot(i)
            slots[i] = s
            s:SetSize(size, size)
            s.glow.halo:SetSize(size * 1.9, size * 1.9) -- the texture's glow ring sits inside its edges
            s.count:SetFont(fontPath(), math.max(9, math.floor(size * 0.38)), "OUTLINE")
            s.time:SetFont(fontPath(), math.max(8, math.floor(size * 0.32)), "OUTLINE")
            place(s)
            s.itemID = id
            s.tex:SetTexture(itemIcon(id))
            if b.locked then
                if isWeapon(id) then
                    s:SetAttribute("type1", "macro")
                    s:SetAttribute("macrotext1", "/use item:" .. id .. "\n/use " .. weaponSlot(id))
                    s:SetAttribute("item", nil)
                else
                    s:SetAttribute("type1", "item")
                    s:SetAttribute("item", "item:" .. id)
                    s:SetAttribute("macrotext1", nil)
                end
            else
                s:SetAttribute("type1", nil) -- unlocked = moving the bar: clicks use nothing
            end
            s:Show()
        end
        for i = #items + 1, #slots do slots[i].itemID = nil; slots[i]:Hide() end

        local showAdd = unlocked or #items == 0
        bar.add:SetShown(showAdd)
        if showAdd then bar.add:SetSize(size, size); place(bar.add) end

        local ar, ag, ab = bar.accent[1], bar.accent[2], bar.accent[3]
        if unlocked then bar.edges:SetColor(ar, ag, ab, 1) else bar.edges:SetColor(1, 1, 1, 0.15) end
        bar.dragLabel:SetShown(unlocked)
        bar.lockBtn:SetShown(unlocked)
        bar.gearBtn:SetShown(unlocked)
        local length = BAR_GAP + math.max(n, 1) * (size + BAR_GAP)
        if grow == "UP" or grow == "DOWN" then bar:SetSize(size + BAR_GAP * 2, length)
        else bar:SetSize(length, size + BAR_GAP * 2) end
        applyAnchor()
        bar:Show()
    end

    function B.refresh()
        local ok, err = pcall(layout)
        if not ok and not errorShown then
            errorShown = true
            out(label .. " error: " .. tostring(err))
        end
    end
    function B.pending() return layoutPending end
    function B.safeVisuals()
        local ok, err = pcall(updateVisuals)
        if not ok and not errorShown then
            errorShown = true
            out(label .. " error: " .. tostring(err))
        end
    end
    function B.shown() return bar and bar:IsShown() end

    menuOpen = function(slot)
        local id = slot.itemID
        if not id then return end
        local entries = {}
        local kind = kindOf(id)
        if kind == "weapon" then
            local off = weaponSlot(id) == 17
            entries[#entries + 1] = { off and "Put it on: off hand  (switch to main hand)" or "Put it on: main hand  (switch to off hand)", function()
                if not changeAllowed(label) then return end
                itemOpts(id).offhand = not off or nil
                R.refreshAll()
            end }
        end
        if kind == "buff" or kind == "weapon" or kind == "unknown" then
            local on = reminds(id)
            entries[#entries + 1] = { (on and "Orange glow when missing: on" or "Orange glow when missing: off") .. "  (click to switch)", function()
                itemOpts(id).remind = not on
                R.visualsAll()
            end }
        end
        local items = charDB().items
        local pos = 0
        for i, have in ipairs(items) do if have == id then pos = i end end
        local EARLIER = { RIGHT = "Move left", LEFT = "Move right", UP = "Move down", DOWN = "Move up" }
        local LATER = { RIGHT = "Move right", LEFT = "Move left", UP = "Move up", DOWN = "Move down" }
        local grow = db().grow or "RIGHT"
        if pos > 1 then entries[#entries + 1] = { EARLIER[grow], function() moveItem(id, -1) end } end
        if pos < #items then entries[#entries + 1] = { LATER[grow], function() moveItem(id, 1) end } end
        local other = BARS[cfg.other]
        if other then entries[#entries + 1] = { "Move to the " .. other.cfg.label, function() sendTo(other, id) end } end
        entries[#entries + 1] = { "Load a preset...", function() presetMenu(slot, vertical()) end }
        entries[#entries + 1] = { "|cffff6060Remove from the " .. label .. "|r", function() removeItem(id) end }
        showMenu(slot, itemName(id), entries, vertical())
    end

    function B.resetPosition()
        if not changeAllowed(label, "move") then return end
        db().pos = nil
        if bar then bar:ClearAllPoints(); bar:SetPoint("CENTER", UIParent, "CENTER", 0, cfg.y) end
    end

    function B.isShown() return db().show ~= "hide" end
    function B.toggleShown()
        local b = db()
        if not changeAllowed(label, "be shown or hidden") then return end
        if b.show == "hide" then b.show = b.lastShow or "always"
        else b.lastShow = b.show; b.show = "hide" end
        R.refreshAll()
        if NS.panelRefresh then NS.panelRefresh() end
    end

    function B.get(what)
        local b = db()
        if what == "Show" then return b.show
        elseif what == "Glow" then return b.glow
        elseif what == "Lock" then return b.locked
        elseif what == "Grow" then return b.grow end
    end
    function B.set(what, v)
        local b = db()
        if what == "Glow" then b.glow = v; R.visualsAll(); return end
        if not changeAllowed(label) then return end
        if what == "Show" then if v ~= "hide" then b.lastShow = v end b.show = v
        elseif what == "Lock" then b.locked = v
        elseif what == "Grow" then
            if b.grow == v then return end
            b.grow = v
            if bar and bar:IsShown() then savePos() end -- stays where it is, pinned on the new side
        end
        R.refreshAll()
    end

    function B.list()
        local items = charDB().items
        if #items == 0 then out("your " .. label .. " is empty - drag items from your bags onto it"); return end
        out(label .. ":")
        for i, id in ipairs(items) do
            local kind = kindOf(id)
            out(string.format("  %d. %s [%d] - %s, %d in bags", i, itemName(id), id,
                kind == "weapon" and ("weapon, " .. (weaponSlot(id) == 17 and "off hand" or "main hand"))
                or kind == "buff" and ("buff" .. (reminds(id) and "" or ", no orange glow"))
                or kind == "none" and "no lasting buff" or "buff not learned yet",
                (getCount and getCount(id)) or 0))
        end
    end

    BARS[cfg.key] = B
    BAR_LIST[#BAR_LIST + 1] = B
    return B
end

newBar({ key = "raid", other = "stims", label = "raid bar", addTitle = "Add a raid buff consumable",
         dbKey = "raidBar", charKey = "raid", frame = "ProvisionsRaidBar", button = "ProvisionsRaidButton",
         y = -140, glow = "both", sub = 1 })
newBar({ key = "stims", other = "raid", label = "raid stims bar", addTitle = "Add a raid stim",
         dbKey = "stimsBar", charKey = "stims", frame = "ProvisionsStimsBar", button = "ProvisionsStimsButton",
         y = -190, glow = "active", sub = 2 })

function R.refreshAll()
    for _, B in ipairs(BAR_LIST) do B.refresh() end
    R.visualsAll()
    if NS.refreshBarToggles then pcall(NS.refreshBarToggles) end
end
function R.isShown(key) return BARS[key] and BARS[key].isShown() end
function R.toggleShown(key) if BARS[key] then BARS[key].toggleShown() end end
function R.visualsAll()
    pcall(scanAuras)
    for _, B in ipairs(BAR_LIST) do if B.shown() then B.safeVisuals() end end
end
R.refresh = R.refreshAll

---------------------------------------------------------------- one-time tidy-up of v1.7 test lists
-- Short-use items leave the raid bar for the raid stims bar; runes leave for the main item bar.
local function migrate()
    ProvisionsCharDB = ProvisionsCharDB or {}
    local c = ProvisionsCharDB
    if c.raidSplit then return end
    c.raidSplit = true
    local raid, stims = BARS.raid.char(), BARS.stims.char()
    local keep, moved, runes = {}, 0, 0
    for _, id in ipairs(raid.items) do
        if RUNES[id] then runes = runes + 1; raid.opts[id] = nil
        elseif KNOWN[id] == "stim" then
            local dup = false
            for _, have in ipairs(stims.items) do if have == id then dup = true end end
            if not dup then stims.items[#stims.items + 1] = id end
            if raid.opts[id] then stims.opts[id] = raid.opts[id]; raid.opts[id] = nil end
            moved = moved + 1
        else keep[#keep + 1] = id end
    end
    raid.items = keep
    if moved > 0 then out(moved .. " short-use item(s) moved from the raid bar to the new raid stims bar") end
    if runes > 0 then out("runes now live on the main item bar (Rune macro) and were taken off the raid bar") end
end

---------------------------------------------------------------- presets
function R.presets() return PRESETS end

-- mode "add": append what's missing, keep your lists and order. "replace": the preset becomes your lists.
function R.applyPreset(key, mode)
    local p = PRESET_BY_KEY[key]
    if not p then out("no preset called \"" .. tostring(key) .. "\""); return end
    if InCombatLockdown() then out("presets can't be loaded during combat - try again after the fight"); return end
    local added = 0
    for _, which in ipairs({ "raid", "stims" }) do
        local c = BARS[which].char()
        if mode == "replace" then wipe(c.items) end
        local have = {}
        for _, id in ipairs(c.items) do have[id] = true end
        for _, id in ipairs(p[which] or {}) do
            if not have[id] then
                c.items[#c.items + 1] = id
                have[id] = true
                added = added + 1
                if requestItem then pcall(requestItem, id) end
            end
        end
    end
    if mode == "replace" then
        out("raid bar and raid stims bar set to the " .. p.name .. " preset. Right-click an icon to remove what you don't use.")
    else
        out(p.name .. " preset: added " .. added .. " item(s) to your raid bar and raid stims bar.")
    end
    R.refreshAll()
end

StaticPopupDialogs["PROVISIONS_RAID_PRESET"] = {
    text = "Load the %s preset onto this character's raid bar and raid stims bar?\n\n%s\n\nAdd missing keeps your lists and adds what's not on them. Replace makes the preset your lists.",
    button1 = "Add missing",
    button2 = "Cancel",
    button3 = "Replace",
    OnAccept = function(_, data) R.applyPreset(data, "add") end,
    OnAlt = function(_, data) R.applyPreset(data, "replace") end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
function R.askPreset(key)
    local p = PRESET_BY_KEY[key]
    if not p then return end
    if #BARS.raid.char().items == 0 and #BARS.stims.char().items == 0 then R.applyPreset(key, "add"); return end
    local dialog = StaticPopup_Show("PROVISIONS_RAID_PRESET", p.name, p.note)
    if dialog then dialog.data = key end
end

---------------------------------------------------------------- settings (used by the settings window)
-- keys: raidShow, raidGlow, raidLock, raidGrow, stimsShow, stimsGlow, stimsLock, stimsGrow
local function split(key)
    local which, what = key:match("^(raid)(%u%a*)$")
    if not which then which, what = key:match("^(stims)(%u%a*)$") end
    return BARS[which or ""], what
end
function R.get(key) local B, what = split(key); return B and B.get(what) end
function R.set(key, v) local B, what = split(key); if B then B.set(what, v) end end
function R.resetPosition() for _, B in ipairs(BAR_LIST) do B.resetPosition() end end

-- /prov raid ... and /prov stims ...   (input keeps its case so item links survive)
function R.slash(which, input)
    local B = BARS[which] or BARS.raid
    input = input or ""
    local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "add" then
        local id = tonumber(rest:match("item:(%d+)") or rest:match("^(%d+)$"))
        if not id and rest ~= "" and GetItemInfo then
            local _, link = GetItemInfo(rest) -- an item name you have seen this session
            id = link and tonumber(link:match("item:(%d+)"))
        end
        if id then B.addItem(id) else out("usage: /prov " .. which .. " add <shift-click an item, or its ID>") end
    elseif cmd == "list" then
        B.list()
    elseif cmd == "preset" then
        local key, mode = rest:lower():match("^(%S*)%s*(%S*)")
        if key == "" then
            local names = {}
            for _, p in ipairs(PRESETS) do names[#names + 1] = p.key .. " (" .. p.name .. ")" end
            out("presets (fill both bars): " .. table.concat(names, ", ") .. ". Usage: /prov raid preset <name> [replace]")
        else
            R.applyPreset(key, mode == "replace" and "replace" or "add")
        end
    elseif cmd == "clear" then
        if not changeAllowed(B.cfg.label) then return end
        wipe(B.char().items)
        out(B.cfg.label .. " emptied for this character")
        R.refreshAll()
    else
        out("/prov " .. which .. " add <item> = add an item (or drag it onto the bar), /prov " .. which
            .. " list, /prov " .. which .. " clear, /prov raid preset <name> [replace] = fill both bars")
    end
end

---------------------------------------------------------------- events
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, a1, _, a3)
    if event == "PLAYER_REGEN_ENABLED" then
        local any = false
        for _, B in ipairs(BAR_LIST) do if B.pending() then any = true end end
        if any then R.refreshAll() else R.visualsAll() end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" or event == "ZONE_CHANGED_NEW_AREA" then
        if event == "PLAYER_ENTERING_WORLD" then
            pcall(migrate)
            C_Timer.After(3, R.refreshAll)
        end
        R.refreshAll()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" or not a3 or not GetItemSpell or isSecret(a3) then return end
        noteUsedInFight(a3)
        if aurasLocked then R.visualsAll(); return end -- learning waits for a fight-free use
        -- one of your bar items was used: if its buff never shows up, it's an instant item (no glow)
        for _, B in ipairs(BAR_LIST) do
            for _, id in ipairs(B.char().items) do
                if kindOf(id) == "unknown" then
                    local _, sID = GetItemSpell(id)
                    if sID == a3 then
                        C_Timer.After(1, function()
                            pcall(scanAuras)
                            if aurasLocked then return end -- can't tell in combat: try again next time
                            local active = buffState(id)
                            if active == nil and kindOf(id) == "unknown" then learned().buff[id] = false end
                            R.visualsAll()
                        end)
                    end
                end
            end
        end
    else
        R.visualsAll()
    end
end)
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE", "ZONE_CHANGED_NEW_AREA",
                     "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "SPELL_UPDATE_COOLDOWN", "GET_ITEM_INFO_RECEIVED",
                     "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "UNIT_SPELLCAST_SUCCEEDED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
pcall(ev.RegisterUnitEvent, ev, "UNIT_AURA", "player")
pcall(ev.RegisterUnitEvent, ev, "UNIT_INVENTORY_CHANGED", "player")

-- buff timers count down: refresh once a second while a bar is up
C_Timer.NewTicker(1, function()
    for _, B in ipairs(BAR_LIST) do if B.shown() then R.visualsAll(); return end end
end)
