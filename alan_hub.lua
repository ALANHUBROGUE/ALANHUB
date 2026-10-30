-- Alan Hub - Rogue Lineage (Matcha LuaVM)
--   * Leaderboard spectate (silent)
--   * Trinket ESP
--   * Last looted timers (Castle Rock, Temple of Fire, Deep Sunken, Crypt of Kings)
--   * Better mana charge: hold G and charging restarts by itself whenever it gets interrupted
--   * Hold block (F): keeps re-sending Block while F is held (needs Matcha Pro / FireServer)
-- Settings live in Matcha's menu, tab "Alan Hub".
--
-- Spectate:  right-click a leaderboard name to spectate, again to stop, another name to switch.
--            Hover a name until it shows the username if it is not recognised yet.
--            "Stop spectating" button in the menu. Needs Unsafe Lua enabled in Matcha.
-- Trinket ESP: on/off, range, max shown, types and "ignore range" are in the menu.
-- No hotkeys. Silent: nothing is printed unless the menu tab fails to load.

----------------------------------------------------------------------
-- Services / single instance
----------------------------------------------------------------------
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

if _G.AlanHub and type(_G.AlanHub.cleanup) == "function" then pcall(_G.AlanHub.cleanup) end
if _G.RLHub and type(_G.RLHub.cleanup) == "function" then pcall(_G.RLHub.cleanup) end
if _G.RLSpectate and type(_G.RLSpectate.cleanup) == "function" then pcall(_G.RLSpectate.cleanup) end
local GEN = tick()
_G.AlanHubGen = GEN

local TAB_NAME = "Alan Hub"

----------------------------------------------------------------------
-- Menu values
----------------------------------------------------------------------
local RARITIES = { "common", "rare", "mythic", "artifact", "event" }

local DEFAULTS = {
    spec_enabled  = true,
    esp_enabled   = true,
    esp_area      = true,
    esp_alert     = true,
    esp_range     = 200,
    esp_max       = 60,
    types_common  = false, types_rare = false, types_mythic = true, types_artifact = true, types_event = false,
    mana_on       = false,
    block_on      = false,
    block_delay   = 0,
    far_common    = false, far_rare  = false, far_mythic  = true, far_artifact  = true, far_event  = false,
}

local uiReady = false
local function ui(id)
    local d = DEFAULTS[id]
    if not uiReady then return d end
    local ok, v = pcall(UI.GetValue, "rl_" .. id)
    if ok and v ~= nil then return v end
    return d
end


----------------------------------------------------------------------
-- Shared helpers
----------------------------------------------------------------------
local function prop(inst, name)
    local ok, v = pcall(function() return inst[name] end)
    if ok then return v end
    return nil
end

local function norm(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("<[^>]->", "")
    s = s:gsub("\226\128[\139-\143]", "")
    s = s:match("^%s*(.-)%s*$")
    if not s or s == "" then return nil end
    return s:lower()
end

local function safeConnect(container, eventName, fn)
    local ok, conn = pcall(function()
        local sig = container[eventName]
        if sig == nil then return nil end
        return sig:Connect(fn)
    end)
    if ok then return conn end
    return nil
end

local clock = (os and os.clock) or tick

local target = nil          -- who is being spectated (set by the spectate code below)
local lootLines = {}        -- "Last looted" lines shown in the menu (filled by the timer code below)
local lootStatus = ""       -- clock source + last refresh, shown under the timers
local refreshLoot, printLoot -- assigned below

local LOOT_AREAS = {
    { label = "Castle Rock",    trigger = "CastleRockSnake" },
    { label = "Temple of Fire", trigger = "MazeSnakes" },
    { label = "Deep Sunken",    trigger = "evileye2" },
    { label = "Crypt of Kings", trigger = "CryptTrigger" },
}

-- Matcha's menu does not redraw sec:Text() labels, so live values are shown in
-- InputText fields and pushed with UI.SetValue (documented to update a widget).
local function setField(id, value)
    pcall(UI.SetValue, id, value)
end
local stopSpectate          -- assigned below

--====================================================================
-- MENU TAB (registered first, so nothing later in the file can prevent it)
--====================================================================
local RARITY_LABEL = { common = "Common", rare = "Rare", mythic = "Mythic", artifact = "Artifact", event = "Event" }
local menuError = nil

local function renderTab(tab)
    local sp = tab:Section("Spectate", "Left")
    sp:Toggle("rl_spec_enabled", "Leaderboard spectate", DEFAULTS.spec_enabled)
    sp:Tip("Right-click a leaderboard name to spectate, again to stop")
    sp:Button("Stop spectating", function()
        if stopSpectate then stopSpectate() end
    end)
    sp:InputText("rl_spec_target", "Spectating", "nobody")


    local cb = tab:Section("Combat", "Left")
    cb:Toggle("rl_mana_on", "Better mana charge (hold G)", DEFAULTS.mana_on)
    cb:Tip("While G is held, re-presses G whenever charging gets interrupted")
    cb:Toggle("rl_block_on", "Hold block (F)", DEFAULTS.block_on)
    cb:Tip("While F is held, keeps sending Block (needs Matcha Pro / FireServer)")
    cb:SliderInt("rl_block_delay", "Block delay (ms)", 0, 1000, DEFAULTS.block_delay)
    cb:InputText("rl_block_status", "Block status", "off")

    local lt = tab:Section("Last looted", "Left")
    for i, a in ipairs(LOOT_AREAS) do
        lt:InputText("rl_loot_" .. i, a.label, "...")
    end
    lt:InputText("rl_loot_status", "Status", "...")
    lt:Button("Refresh", function()
        if refreshLoot then refreshLoot() end
    end)
    lt:Button("Print to console", function()
        if printLoot then printLoot() end
    end)

    local es = tab:Section("Trinket ESP", "Right", { "Main", "Types", "Ignore range" })
    if es.page == 0 then
        es:Toggle("rl_esp_enabled", "Trinket ESP", DEFAULTS.esp_enabled)
        es:Toggle("rl_esp_area", "Show area", DEFAULTS.esp_area)
        es:Toggle("rl_esp_alert", "Phoenix Down alert", DEFAULTS.esp_alert)
        es:SliderInt("rl_esp_range", "Range", 10, 300, DEFAULTS.esp_range)
        es:SliderInt("rl_esp_max", "Max shown", 5, 100, DEFAULTS.esp_max)
    elseif es.page == 1 then
        for _, r in ipairs(RARITIES) do
            es:Toggle("rl_types_" .. r, RARITY_LABEL[r], DEFAULTS["types_" .. r])
        end
    else
        for _, r in ipairs(RARITIES) do
            es:Toggle("rl_far_" .. r, RARITY_LABEL[r] .. " at any range", DEFAULTS["far_" .. r])
        end
    end
end

if UI == nil then
    warn("[Alan Hub] Matcha's UI library is not available on this build - menu tab not added (features still run with defaults)")
else
    local okTab, errTab = pcall(function()
        UI.AddTab(TAB_NAME, function(tab)
            uiReady = true
            local ok, err = pcall(renderTab, tab)
            if not ok and not menuError then
                menuError = tostring(err)
                warn("[Alan Hub] menu tab error: " .. menuError)
            end
        end)
    end)
    if not okTab then
        warn("[Alan Hub] could not add the menu tab: " .. tostring(errTab))
    end
end

--====================================================================
-- SPECTATE
--====================================================================
local SPEC = {
    MOUSE_Y_OFFSET = 0,
    ROW_WIDTH      = 250,
    REVEAL_WAIT    = 2,
    SCAN_BYTES     = 1536,
    GUI_NAME       = "LeaderboardGui",
    LIVE_NAME      = "Live",
}

local function textOf(d)
    if prop(d, "ClassName") ~= "TextLabel" then return nil end
    local t = prop(d, "Text")
    if type(t) == "string" then return t end
    return nil
end

local function posOf(d)
    local ok, x, y = pcall(function()
        local p = d.AbsolutePosition
        return p.X, p.Y
    end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
    return nil
end

local function getLeaderboard()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    return pg:FindFirstChild(SPEC.GUI_NAME)
end

local function collectRows(gui)
    local rows = {}
    for _, d in ipairs(gui:GetDescendants()) do
        if prop(d, "Name") == "PlayerLabel" then
            local t = textOf(d)
            local x, y = posOf(d)
            if t and x and x > 1 and y > 1 and norm(t) and t ~= "failed to fetch text" then
                rows[#rows + 1] = { node = d, addr = prop(d, "Address"), text = t, x = x, y = y }
            end
        end
    end
    return rows
end

local function rowAt(gui, mx, my)
    local rows = collectRows(gui)
    if #rows == 0 then return nil end
    local ys = {}
    for _, r in ipairs(rows) do ys[#ys + 1] = r.y end
    table.sort(ys)
    local h = 0
    for i = 2, #ys do
        local g = ys[i] - ys[i - 1]
        if g >= 5 and (h == 0 or g < h) then h = g end
    end
    if h == 0 then h = 20 end
    local best, bestD
    for _, r in ipairs(rows) do
        if mx >= r.x - 6 and mx <= r.x + SPEC.ROW_WIDTH then
            local d = math.abs(my - (r.y + h / 2))
            if d <= h / 2 + 2 and (not bestD or d < bestD) then best, bestD = r, d end
        end
    end
    return best
end

local function getLive()
    return Workspace:FindFirstChild(SPEC.LIVE_NAME)
end

local function findSpawned(key)
    local live = getLive()
    if not live or not key then return nil end
    for _, m in ipairs(live:GetChildren()) do
        local n = prop(m, "Name")
        if n and norm(n) == key then return n end
    end
    return nil
end

local function getModel(name)
    local live = getLive()
    if not live then return nil end
    local m = live:FindFirstChild(name)
    if m and prop(m, "Parent") then return m end
    return nil
end

local function myModel()
    local live = getLive()
    local m = live and live:FindFirstChild(LocalPlayer.Name)
    if m then return m end
    return prop(LocalPlayer, "Character")
end

local function myCharacterKey()
    local key
    pcall(function()
        key = norm(prop(LocalPlayer.PlayerGui.StatGui.Container.CharacterName, "Text"))
    end)
    return key
end

local function usernameSet()
    local set = {}
    for _, p in ipairs(Players:GetPlayers()) do
        local k = norm(prop(p, "Name"))
        if k then set[k] = true end
    end
    return set
end

local rowMemory = {}
local rpgToUser = {}
local nextSample = 0

local function sampleRows()
    if tick() < nextSample then return end
    nextSample = tick() + 0.5
    local gui = getLeaderboard()
    if not gui then return end
    local users = usernameSet()
    for _, r in ipairs(collectRows(gui)) do
        local k = norm(r.text)
        if r.addr and k then
            local m = rowMemory[r.addr]
            if not m then
                m = {}
                rowMemory[r.addr] = m
            end
            if users[k] then
                m.user = k
            elseif m.rpg ~= k then
                m.rpg = k
                m.user = nil
            end
            if m.rpg and m.user then rpgToUser[m.rpg] = m.user end
        end
    end
end

local function resolveKey(key)
    local name = findSpawned(key)
    if name then return name end
    local user
    if usernameSet()[key] then user = key else user = rpgToUser[key] end
    if user then return findSpawned(user), "not spawned" end
    return nil, "unknown"
end

-- memory: camera subject
local mem = { ok = false, offset = nil, kind = nil }
local sub = nil
local KINDS = { "Humanoid", "HumanoidRootPart", "Head", "Torso", "Model" }

local function addrOf(inst)
    if not inst then return nil end
    local a = prop(inst, "Address")
    if type(a) == "string" then a = tonumber(a) end
    if type(a) == "number" and a > 0 then return a end
    return nil
end

local function partOfKind(model, kind)
    if not model then return nil end
    if kind == "Humanoid" then return model:FindFirstChildOfClass("Humanoid") end
    if kind == "Model" then return model end
    return model:FindFirstChild(kind)
end

local function readPtr(a)
    local ok, v = pcall(memory_read, "uintptr_t", a)
    if ok and type(v) == "number" then return v end
    return nil
end

local function discover()
    if mem.ok then return true end
    if type(memory_read) ~= "function" or type(memory_write) ~= "function" then return false end
    local camAddr = addrOf(Workspace.CurrentCamera)
    local mine = myModel()
    if not camAddr or not mine then return false end
    local wanted = {}
    for _, k in ipairs(KINDS) do
        local a = addrOf(partOfKind(mine, k))
        if a then wanted[#wanted + 1] = { kind = k, addr = a } end
    end
    local hit, count = nil, 0
    for off = 0, SPEC.SCAN_BYTES, 8 do
        local v = readPtr(camAddr + off)
        if v == nil then return false end
        if v ~= 0 then
            for _, w in ipairs(wanted) do
                if v == w.addr then
                    hit = { off = off, kind = w.kind }
                    count = count + 1
                end
            end
        end
    end
    if count ~= 1 then return false end
    mem.offset, mem.kind, mem.ok = hit.off, hit.kind, true
    return true
end

local function memStart(model)
    if not discover() then return false end
    local camAddr = addrOf(Workspace.CurrentCamera)
    local tAddr = addrOf(partOfKind(model, mem.kind))
    local myAddr = addrOf(partOfKind(myModel(), mem.kind))
    if not camAddr or not tAddr or not myAddr then return false end
    if readPtr(camAddr + mem.offset) ~= myAddr then
        mem.ok = false
        return false
    end
    if not pcall(memory_write, "uintptr_t", camAddr + mem.offset, tAddr) then return false end
    sub = { camAddr = camAddr }
    return true
end

local function memRestore()
    if not sub then return end
    local s0 = sub
    sub = nil
    local myAddr = addrOf(partOfKind(myModel(), mem.kind)) or 0
    pcall(memory_write, "uintptr_t", s0.camAddr + mem.offset, myAddr)
end

local function memStep(model)
    local part = partOfKind(model, mem.kind)
    local tAddr = addrOf(part)
    if not tAddr or not prop(part, "Parent") or not prop(model, "Parent") then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then
        local hp = prop(hum, "Health")
        if type(hp) == "number" and hp <= 0 then return false end
    end
    local camAddr = addrOf(Workspace.CurrentCamera)
    if camAddr ~= sub.camAddr then return false end
    if readPtr(camAddr + mem.offset) ~= tAddr then
        pcall(memory_write, "uintptr_t", camAddr + mem.offset, tAddr)
    end
    return true
end

stopSpectate = function()
    memRestore()
    target = nil
end

local function startSpectate(name)
    local model = getModel(name)
    if not model then return end
    memRestore()
    if memStart(model) then target = name else target = nil end
end

local function toggleSpectate(name)
    if name == LocalPlayer.Name or target == name then
        stopSpectate()
    else
        startSpectate(name)
    end
end

local pending = nil

local function handleKey(key, node)
    if not key then return end
    if key == myCharacterKey() or key == norm(LocalPlayer.Name) then
        stopSpectate()
        return
    end
    local name, why = resolveKey(key)
    if name then
        pending = nil
        toggleSpectate(name)
    elseif why == "not spawned" then
        pending = nil
    else
        pending = { node = node, key = key, untilT = tick() + SPEC.REVEAL_WAIT }
    end
end

local function checkPending()
    if not pending then return end
    if tick() > pending.untilT then
        pending = nil
        return
    end
    local k = norm(textOf(pending.node))
    if k and k ~= pending.key and usernameSet()[k] then
        rpgToUser[pending.key] = k
        local node = pending.node
        pending = nil
        handleKey(k, node)
    end
end

local function onRightClick()
    local gui = getLeaderboard()
    if not gui then return end
    local row = rowAt(gui, Mouse.X, Mouse.Y + SPEC.MOUSE_Y_OFFSET)
    if row then handleKey(norm(row.text), row.node) end
end

local rightWasDown = false

local function spectateFrame(active)
    if not ui("spec_enabled") then
        if target then stopSpectate() end
        pending = nil
        rightWasDown = ismouse2pressed()
        return
    end

    pcall(sampleRows)
    pcall(checkPending)

    local down = ismouse2pressed()
    if down and not rightWasDown and active then pcall(onRightClick) end
    rightWasDown = down

    if target then
        local ok, alive = pcall(function()
            local model = getModel(target)
            return model ~= nil and memStep(model)
        end)
        if not ok or not alive then stopSpectate() end
    end
end

--====================================================================
-- TRINKET ESP
--====================================================================
local vpW, vpH = 1920, 1080

local function refreshViewport()
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local vp = prop(cam, "ViewportSize")
    if vp and vp.X > 0 and vp.Y > 0 then
        vpW = vp.X
        vpH = vp.Y
    end
end

local function clampScreen(v2)
    local x, y = v2.X, v2.Y
    if x ~= x or y ~= y then return nil end
    if math.abs(x) > 1000000 or math.abs(y) > 1000000 then return nil end
    return Vector2.new(math.clamp(x, 0, vpW), math.clamp(y, 0, vpH))
end

local function safeWorldToScreen(pos)
    local screenPos, onScreen = WorldToScreen(pos)
    if not onScreen then return nil end
    return clampScreen(screenPos)
end

local function safeRead(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local MESHID_PTR_OFFSET = 0xF8

local function readRobloxString(addr)
    if not addr or addr == 0 then return nil end
    local length = memory_read("uintptr_t", addr + 0x10)
    if not length or length == 0 or length > 512 then return nil end
    local dataPtr = length < 16 and addr or memory_read("uintptr_t", addr)
    if not dataPtr or dataPtr == 0 then return nil end
    local chars = {}
    for i = 0, length - 1 do
        local b = memory_read("byte", dataPtr + i)
        if not b then break end
        chars[#chars + 1] = string.char(b)
    end
    return table.concat(chars)
end

local function readMeshId(part)
    if not part or prop(part, "ClassName") ~= "MeshPart" then return nil end
    local base = addrOf(part)
    if not base then return nil end
    local ok, raw = pcall(function()
        local meshIdPtr = memory_read("uintptr_t", base + MESHID_PTR_OFFSET)
        if not meshIdPtr or meshIdPtr == 0 then return nil end
        return readRobloxString(meshIdPtr)
    end)
    if not ok or not raw or raw == "" then return nil end
    return raw:match("rbxassetid://(%d+)") or (raw:match("^%d+$") and raw) or nil
end

local MESH_ID_MAP = {
    ["5196782997"] = { name = "Old Ring",                 rarity = "common"   },
    ["5196776695"] = { name = "Ring",                     rarity = "common"   },
    ["5204003946"] = { name = "Goblet",                   rarity = "common"   },
    ["5196577540"] = { name = "Old Amulet",               rarity = "common"   },
    ["5196551436"] = { name = "Amulet",                   rarity = "common"   },
    ["5204453430"] = { name = "Scroll",                   rarity = "rare"     },
    ["5197099782"] = { name = "Amulet of the White King", rarity = "artifact" },
    ["5196963069"] = { name = "Lannis Amulet",            rarity = "artifact" },
    ["4103271893"] = { name = "Candy",                    rarity = "event"    },
    ["2520762076"] = { name = "Howler Friend",            rarity = "artifact" },
    ["2877143560"] = { name = "Gem",                      rarity = "rare"     },
    ["4027112893"] = { name = "Bound Book",               rarity = "rare"     },
}

local RARITY_STYLE = {
    common   = { Color = Color3.fromRGB(200, 200, 200), ZIndex = 1 },
    rare     = { Color = Color3.fromRGB(100, 149, 237), ZIndex = 2 },
    mythic   = { Color = Color3.fromRGB(180,  80, 255), ZIndex = 3 },
    artifact = { Color = Color3.fromRGB(255, 165,   0), ZIndex = 4 },
    event    = { Color = Color3.fromRGB( 50, 205,  50), ZIndex = 5 },
}

-- returns name, rarity
local function identifyTrinket(v)
    local cls = prop(v, "ClassName")
    if not cls then return nil end

    local hasAttachment  = v:FindFirstChild("Attachment") ~= nil
    local hasOrbParticle = v:FindFirstChild("OrbParticle") ~= nil
    local hasSpecialMesh = v:FindFirstChildOfClass("SpecialMesh") ~= nil
    local hasDirectPE    = v:FindFirstChildOfClass("ParticleEmitter") ~= nil

    local meshChildCount = 0
    for _, c in ipairs(v:GetChildren()) do
        if prop(c, "ClassName") == "MeshPart" then meshChildCount = meshChildCount + 1 end
    end

    local attHasPE = false
    if hasAttachment then
        local att = v:FindFirstChild("Attachment")
        for _, c in ipairs(att:GetChildren()) do
            if prop(c, "ClassName") == "ParticleEmitter" then attHasPE = true end
        end
    end

    if cls == "MeshPart" then
        local mid = readMeshId(v)
        local entry = mid and MESH_ID_MAP[mid]
        if entry then return entry.name, entry.rarity end
        if meshChildCount > 0 then
            if v:FindFirstChildOfClass("Weld") ~= nil or meshChildCount >= 2 then return "Scroll", "rare" end
            return "Amulet", "common"
        end
        if hasAttachment and hasDirectPE then return "Amulet", "common" end
        return "Trinket", "common"
    end

    if cls == "Part" then
        if hasSpecialMesh and hasOrbParticle then return "???", "rare" end
        if hasOrbParticle and not hasSpecialMesh then return "Ice Essence", "rare" end
        if hasSpecialMesh and not hasOrbParticle then return "Opal", "rare" end
        if hasAttachment and attHasPE then return "Phoenix Down / Azael Horn", "artifact" end
        if hasDirectPE and not hasSpecialMesh and not hasAttachment then return "Rift Gem", "mythic" end
    end

    if cls == "UnionOperation" then return "Idol", "common" end
    return nil
end

local function detectTrinketArea(trinket)
    local areaMarkers = Workspace:FindFirstChild("AreaMarkers")
    if not areaMarkers then return "None" end
    local trinketPos = safeRead(function() return trinket.Position end)
    if not trinketPos then return "None" end
    local best, bestDist = "None", math.huge
    for _, marker in ipairs(areaMarkers:GetChildren()) do
        local mp = safeRead(function() return marker.Position end)
        if mp then
            local d = (trinketPos - mp).Magnitude
            if d < bestDist then
                best = marker.Name
                bestDist = d
            end
        end
    end
    return best
end

-- Phoenix Down alert (drawn, animated in the main loop)
local NOTIF_W, NOTIF_H, NOTIF_PAD, NOTIF_MARGIN, NOTIF_CORNER = 240, 54, 10, 8, 6
local NOTIF_SLIDE, NOTIF_DURATION, NOTIF_ANIM = 220, 4, 0.18
local notifs = {}

local function removeNotif(n)
    for _, d in ipairs(n.parts) do pcall(function() d:Remove() end) end
    n.done = true
end

local function drawNotif(title, message, color)
    local stack = 0
    for _, n in ipairs(notifs) do
        if not n.done then stack = stack + NOTIF_H + NOTIF_MARGIN end
    end
    local n = { start = clock(), y = NOTIF_MARGIN + stack, done = false, parts = {} }

    local panel = Drawing.new("Square")
    panel.Filled = true; panel.Color = Color3.fromRGB(18, 18, 26)
    panel.Size = Vector2.new(NOTIF_W, NOTIF_H); panel.Corner = NOTIF_CORNER
    panel.ZIndex = 100; panel.Visible = true

    local outline = Drawing.new("Square")
    outline.Filled = false; outline.Color = color
    outline.Size = Vector2.new(NOTIF_W, NOTIF_H); outline.Corner = NOTIF_CORNER
    outline.Thickness = 1; outline.ZIndex = 101; outline.Visible = true

    local accent = Drawing.new("Square")
    accent.Filled = true; accent.Color = color
    accent.Size = Vector2.new(3, NOTIF_H - NOTIF_CORNER * 2)
    accent.ZIndex = 102; accent.Visible = true

    local titleText = Drawing.new("Text")
    titleText.Text = title; titleText.Size = 13; titleText.Font = Drawing.Fonts.SystemBold
    titleText.Color = color; titleText.Outline = true; titleText.ZIndex = 102; titleText.Visible = true

    local msgText = Drawing.new("Text")
    msgText.Text = message; msgText.Size = 11; msgText.Font = Drawing.Fonts.System
    msgText.Color = Color3.fromRGB(200, 200, 200); msgText.Outline = true
    msgText.ZIndex = 102; msgText.Visible = true

    n.parts = { panel, outline, accent, titleText, msgText }
    n.setX = function(x)
        panel.Position     = Vector2.new(x, n.y)
        outline.Position   = Vector2.new(x, n.y)
        accent.Position    = Vector2.new(x + 6, n.y + NOTIF_CORNER)
        titleText.Position = Vector2.new(x + 18, n.y + NOTIF_PAD)
        msgText.Position   = Vector2.new(x + 18, n.y + NOTIF_PAD + 16)
    end
    n.setX(vpW + NOTIF_SLIDE)
    notifs[#notifs + 1] = n
end

local function updateNotifs()
    local keep = {}
    for _, n in ipairs(notifs) do
        if not n.done then
            local elapsed = clock() - n.start
            local total = NOTIF_ANIM + NOTIF_DURATION + NOTIF_ANIM
            local hiddenX = vpW + NOTIF_SLIDE
            local finalX = vpW - NOTIF_W - NOTIF_MARGIN
            if elapsed > total then
                removeNotif(n)
            else
                local x
                if elapsed < NOTIF_ANIM then
                    local t = 1 - (1 - elapsed / NOTIF_ANIM) ^ 3
                    x = hiddenX + (finalX - hiddenX) * t
                elseif elapsed < NOTIF_ANIM + NOTIF_DURATION then
                    x = finalX
                else
                    local t = ((elapsed - NOTIF_ANIM - NOTIF_DURATION) / NOTIF_ANIM) ^ 3
                    x = finalX + (hiddenX - finalX) * t
                end
                pcall(n.setX, math.floor(x))
                keep[#keep + 1] = n
            end
        end
    end
    notifs = keep
end

-- ESP objects
local espList = {}
local espByAddress = {}

local function hideEsp(e)
    if not e.visible then return end
    for _, d in ipairs(e.parts) do d.Visible = false end
    e.visible = false
end

local function removeEsp(e)
    for _, d in ipairs(e.parts) do pcall(function() d:Remove() end) end
    if e.addr then espByAddress[e.addr] = nil end
    e.removed = true
end

local function newLine(color, zi, thick)
    local l = Drawing.new("Line")
    l.Thickness = thick; l.Color = color; l.ZIndex = zi; l.Visible = false
    return l
end

local function addTrinketEsp(trinket, name, rarity)
    local addr = addrOf(trinket)
    if not addr or espByAddress[addr] then return end
    local style = RARITY_STYLE[rarity] or RARITY_STYLE.common
    local color, zi = style.Color, style.ZIndex + 10
    local isPhoenix = (name == "Phoenix Down / Azael Horn")

    if isPhoenix and ui("esp_alert") then
        local pos = safeRead(function() return trinket.Position end)
        local posStr = pos and ("X:" .. math.floor(pos.X) .. " Y:" .. math.floor(pos.Y) .. " Z:" .. math.floor(pos.Z))
            or "unknown position"
        pcall(drawNotif, "Phoenix Down", posStr, color)
    end

    local dot = Drawing.new("Circle")
    dot.Radius = 4; dot.NumSides = 12; dot.Filled = true
    dot.Color = color; dot.ZIndex = zi; dot.Visible = false

    local dotOutline = Drawing.new("Circle")
    dotOutline.Radius = 5; dotOutline.NumSides = 12; dotOutline.Filled = false
    dotOutline.Thickness = 1; dotOutline.Color = Color3.fromRGB(0, 0, 0)
    dotOutline.ZIndex = zi - 1; dotOutline.Visible = false

    local line = newLine(color, zi, 1)

    local label = Drawing.new("Text")
    label.Center = true; label.Outline = true; label.Font = Drawing.Fonts.SystemBold
    label.Size = 13; label.Color = color; label.ZIndex = zi + 1; label.Visible = false

    local shaft = newLine(color, zi + 2, 2)
    local wingL = newLine(color, zi + 2, 2)
    local wingR = newLine(color, zi + 2, 2)

    local e = {
        object = trinket, addr = addr, name = name, rarity = rarity, isPhoenix = isPhoenix,
        area = detectTrinketArea(trinket),
        dot = dot, dotOutline = dotOutline, line = line, label = label,
        shaft = shaft, wingL = wingL, wingR = wingR,
        parts = { dot, dotOutline, line, label, shaft, wingL, wingR },
        visible = false, lastText = "", lastTextTime = 0,
        dist = math.huge, pos = nil, removed = false,
    }
    espList[#espList + 1] = e
    espByAddress[addr] = e
end

-- false = do not draw; removes the ESP when the trinket is gone
local function precheck(e, camPos, maxRange)
    if prop(e.object, "Parent") == nil then
        hideEsp(e)
        removeEsp(e)
        return false
    end
    local pos = safeRead(function() return e.object.CFrame.Position end)
    if not pos then hideEsp(e); return false end
    e.pos = pos
    e.dist = (camPos - pos).Magnitude
    if not ui("types_" .. e.rarity) then hideEsp(e); return false end
    if not ui("far_" .. e.rarity) and e.dist >= maxRange then hideEsp(e); return false end
    return true
end

local function hideArrow(e)
    e.shaft.Visible = false; e.wingL.Visible = false; e.wingR.Visible = false
end

local function drawArrow(e)
    if not e.isPhoenix then hideArrow(e); return end
    local char = prop(LocalPlayer, "Character")
    local torso = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso"))
    if not torso or not e.pos then hideArrow(e); return end

    local ts, tOn = WorldToScreen(torso.Position)
    if not tOn then hideArrow(e); return end
    ts = clampScreen(ts)
    if not ts then hideArrow(e); return end

    local ps = safeWorldToScreen(e.pos)
    if not ps then ps = WorldToScreen(e.pos) end
    if not ps then hideArrow(e); return end

    local dx, dy = ps.X - ts.X, ps.Y - ts.Y
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < 1 then hideArrow(e); return end
    local nx, ny = dx / mag, dy / mag

    local SHAFT_LEN, HEAD_LEN, HEAD_ANGLE = 40, 12, math.rad(35)
    local tipX, tipY = ts.X + nx * SHAFT_LEN, ts.Y + ny * SHAFT_LEN
    local cosA, sinA = math.cos(HEAD_ANGLE), math.sin(HEAD_ANGLE)
    local lx = 0 - (nx * cosA - ny * sinA)
    local ly = 0 - (nx * sinA + ny * cosA)
    local rx = 0 - (nx * cosA + ny * sinA)
    local ry = 0 - ((0 - nx) * sinA + ny * cosA)

    e.shaft.From = ts; e.shaft.To = Vector2.new(tipX, tipY); e.shaft.Visible = true
    e.wingL.From = Vector2.new(tipX, tipY); e.wingL.To = Vector2.new(tipX + lx * HEAD_LEN, tipY + ly * HEAD_LEN); e.wingL.Visible = true
    e.wingR.From = Vector2.new(tipX, tipY); e.wingR.To = Vector2.new(tipX + rx * HEAD_LEN, tipY + ry * HEAD_LEN); e.wingR.Visible = true
end

local function drawEsp(e)
    local sp = safeWorldToScreen(e.pos)
    if not sp then hideEsp(e); return end

    local now = clock()
    if now - e.lastTextTime >= 0.2 then
        local areaStr = ""
        if ui("esp_area") and e.area ~= "None" then areaStr = "\n(" .. e.area .. ")" end
        local posStr = ""
        if e.isPhoenix then
            posStr = "\n" .. math.floor(e.pos.X) .. ", " .. math.floor(e.pos.Y) .. ", " .. math.floor(e.pos.Z)
        end
        e.lastText = e.name .. "\n" .. math.floor(e.dist) .. "m" .. areaStr .. posStr
        e.lastTextTime = now
    end

    local lp = clampScreen(Vector2.new(sp.X, math.max(0, sp.Y - 28)))
    if not lp then hideEsp(e); return end
    e.dot.Position = sp; e.dot.Visible = true
    e.dotOutline.Position = sp; e.dotOutline.Visible = true
    e.line.From = sp; e.line.To = lp; e.line.Visible = true
    e.label.Text = e.lastText; e.label.Position = lp; e.label.Visible = true
    e.visible = true
    drawArrow(e)
end

local function scanTrinkets()
    local char = prop(LocalPlayer, "Character")
    local root = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso"))
    if not root then return end
    local rootPos = root.Position
    local limit = ui("esp_range") + 20
    for _, v in ipairs(Workspace:GetChildren()) do
        local ok = pcall(function()
            if (v:IsA("BasePart") or v:IsA("UnionOperation"))
                and v.Name == "Part"
                and v:FindFirstChild("ID")
                and not espByAddress[addrOf(v) or 0]
                and (v.Position - rootPos).Magnitude <= limit then
                local name, rarity = identifyTrinket(v)
                if name then addTrinketEsp(v, name, rarity) end
            end
        end)
        if not ok then
            -- skip this object
        end
    end
end

local function espFrame()
    refreshViewport()
    updateNotifs()

    local enabled = ui("esp_enabled")
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local camPos = cam.CFrame.Position
    local maxRange = ui("esp_range")
    local maxDraw = ui("esp_max")

    local candidates = {}
    for _, e in ipairs(espList) do
        if not e.removed then
            local ok, pass = pcall(precheck, e, camPos, maxRange)
            if ok and pass then candidates[#candidates + 1] = e end
        end
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)

    for i, e in ipairs(candidates) do
        if enabled and i <= maxDraw then
            pcall(drawEsp, e)
        else
            hideEsp(e)
        end
    end

    local keep = {}
    for _, e in ipairs(espList) do
        if not e.removed then keep[#keep + 1] = e end
    end
    espList = keep
end

--====================================================================
-- LAST LOOTED TIMERS
-- Rogue Lineage stores, for every monster spawn trigger, when it last spawned its mobs:
-- workspace.MonsterSpawns.Triggers.<trigger>.LastSpawned (a Unix timestamp, in seconds).
-- The four loot areas are four of those triggers. Walking in / triggering the mobs resets them.
--
-- "Now" comes from os.time() when Matcha provides it. Otherwise it is ESTIMATED from the
-- newest LastSpawned of ALL triggers (mobs spawn all over the map all the time), advanced
-- with tick() - so the timers still work, marked with "~".
--====================================================================
local LOOT_REFRESH = 5          -- seconds between automatic refreshes

local lootValues = {}           -- [trigger] = LastSpawned value from the last read
local lootReadAt = 0            -- tick() of the last read
local lootNext = 0
local est = nil                 -- estimated clock: { unix = n, at = tick() }

local function osNow()
    local ok, t = pcall(function() return os.time() end)
    if ok and type(t) == "number" and t > 1500000000 then return t end
    return nil
end

local function valueOf(trigger)
    local v = trigger and trigger:FindFirstChild("LastSpawned")
    local n = v and prop(v, "Value")
    if type(n) == "string" then n = tonumber(n) end
    if type(n) == "number" and n > 1500000000 then return n end
    return nil
end

-- reads the four areas, and (only when os.time is missing) the newest spawn time of all triggers
local function readLoot(triggers, needEstimate)
    for _, a in ipairs(LOOT_AREAS) do
        lootValues[a.trigger] = valueOf(triggers:FindFirstChild(a.trigger))
    end
    if needEstimate then
        local newest = nil
        for _, trig in ipairs(triggers:GetChildren()) do
            local n = valueOf(trig)
            if n and (not newest or n > newest) then newest = n end
        end
        if newest then
            local advanced = est and (est.unix + (tick() - est.at)) or nil
            if not advanced or newest > advanced then
                est = { unix = newest, at = tick() }
            end
        end
    end
    lootReadAt = tick()
end

local function nowUnix()
    local t = osNow()
    if t then return t, "os.time" end
    if est then return est.unix + (tick() - est.at), "estimated" end
    return nil, "none"
end

local function agoText(seconds)
    if seconds < 0 then seconds = 0 end
    local m = math.floor(seconds / 60)
    if m >= 60 then return math.floor(m / 60) .. "h " .. (m % 60) .. "m ago" end
    return m .. "m ago"
end

local function buildLines(found)
    if not found then
        lootLines = { "Not available on this server" }
        lootStatus = ""
        for i = 1, #LOOT_AREAS do setField("rl_loot_" .. i, "not on this server") end
        setField("rl_loot_status", "MonsterSpawns not found")
        return
    end
    local now, source = nowUnix()
    local mark = (source == "estimated") and "~" or ""
    local lines = {}
    for i, a in ipairs(LOOT_AREAS) do
        local v = lootValues[a.trigger]
        local text
        if not v then
            text = "no data"
        elseif not now then
            text = "no clock"
        else
            local diff = now - v
            if diff > 2592000 then text = "?" else text = mark .. agoText(diff) end
        end
        lines[#lines + 1] = a.label .. ": " .. text
        setField("rl_loot_" .. i, text)
    end
    lootLines = lines
    lootStatus = "clock: " .. source .. "  |  read " .. math.floor(tick() - lootReadAt) .. "s ago"
    setField("rl_loot_status", lootStatus)
end

local lootFound = false

local function doRefresh()
    local spawns = Workspace:FindFirstChild("MonsterSpawns")
    local triggers = spawns and spawns:FindFirstChild("Triggers")
    lootFound = triggers ~= nil
    if triggers then readLoot(triggers, osNow() == nil) end
    buildLines(lootFound)
end

refreshLoot = function()
    lootNext = 0
    pcall(doRefresh)
    lootNext = tick() + LOOT_REFRESH
end

printLoot = function()
    pcall(doRefresh)
    print("[Alan Hub] Last looted:")
    for _, line in ipairs(lootLines) do print("  " .. line) end
    if lootStatus ~= "" then print("  " .. lootStatus) end
end

-- every frame: re-read the game every LOOT_REFRESH seconds, rebuild the text every second
local lootTextNext = 0
local function updateLootTimers()
    local now = tick()
    if now >= lootTextNext then
        setField("rl_spec_target", target and tostring(target) or "nobody")
    end
    if now >= lootNext then
        lootNext = now + LOOT_REFRESH
        pcall(doRefresh)
        lootTextNext = now + 1
    elseif now >= lootTextNext then
        lootTextNext = now + 1
        pcall(buildLines, lootFound)
    end
end

--====================================================================
-- BETTER MANA CHARGE
-- While you hold G, Rogue Lineage puts a "Charge" object on your character. If charging
-- stops while G is still held (hit, stunned, pressed too early), the game will not restart
-- it until G is pressed again. This re-presses G for you (Matcha keyrelease/keypress), with
-- the same timing as the executor version: checks every frame, waits 0.1s + ping/900 after
-- each (re)start of charging.
--====================================================================
local KEY_G = 0x47
local mana = { heldSince = nil, nextTry = 0, phase = nil, phaseAt = 0 }

local function pingDelay()
    local ok, ms = pcall(GetPingValue)
    if ok and type(ms) == "number" and ms > 0 and ms < 2000 then return ms / 900 end
    return 0
end

local function isCharging()
    local m = myModel()
    return m ~= nil and m:FindFirstChild("Charge") ~= nil
end

local function manaFrame(active)
    local now = tick()

    -- step 2 of a re-press: key down again a moment after our release. Runs before the
    -- "is G held" check, because our own release may briefly read as G not held.
    if mana.phase == "released" then
        if now >= mana.phaseAt then
            pcall(keypress, KEY_G)
            mana.phase = nil
            mana.nextTry = now + 0.1 + pingDelay()   -- give the game time to add "Charge"
        end
        return
    end

    local held = iskeypressed(KEY_G)
    if not ui("mana_on") or not active or not held then
        mana.heldSince = nil
        return
    end
    if not mana.heldSince then
        mana.heldSince = now
        mana.nextTry = now + 0.1 + pingDelay()      -- original: 0.1s + ping/900 after the first charge
        return
    end

    if now < mana.nextTry then return end
    if isCharging() then return end

    -- step 1: release G so the game sees a fresh press
    pcall(keyrelease, KEY_G)
    mana.phase = "released"
    mana.phaseAt = now                              -- press again on the very next frame
end

--====================================================================
-- HOLD BLOCK (F)  - same as the executor version
-- While F is held (not while typing in chat), fire the character's
-- CharacterHandler.Remotes.Block with (false) every frame, or every "Block delay" ms.
-- Sending remotes needs FireServer, which Matcha only has in Pro / Hybrid mode.
--====================================================================
local KEY_F = 0x46
local block = { holding = false, last = 0, events = false, status = "off", pushNext = 0 }
local blockConns = {}

pcall(function()
    local UIS = game:GetService("UserInputService")
    local c1 = safeConnect(UIS, "InputBegan", function(input, processed)
        pcall(function()
            if not processed and input.KeyCode == Enum.KeyCode.F then block.holding = true end
        end)
    end)
    local c2 = safeConnect(UIS, "InputEnded", function(input)
        pcall(function()
            if input.KeyCode == Enum.KeyCode.F then block.holding = false end
        end)
    end)
    blockConns = { c1, c2 }
    block.events = (c1 ~= nil and c2 ~= nil)
end)

local function blockFrame(active)
    if not ui("block_on") then
        block.status = "off"
        return
    end
    local holding
    if block.events then
        holding = block.holding
    else
        holding = active and iskeypressed(KEY_F)    -- fallback if input events are unavailable
    end
    if not holding then
        if block.status == "blocking" then block.status = "ready" end
        if block.status == "off" then block.status = "ready" end
        return
    end

    local delay = (tonumber(ui("block_delay")) or 0) / 1000
    local now = tick()
    if now - block.last < delay then return end

    local char = myModel()
    local handler = char and char:FindFirstChild("CharacterHandler")
    local remotes = handler and handler:FindFirstChild("Remotes")
    local remote = remotes and remotes:FindFirstChild("Block")
    if not remote then
        block.status = "Block remote not found"
        return
    end
    local ok = pcall(function() remote:FireServer(false) end)
    if ok then
        block.status = "blocking"
    else
        block.status = "FireServer failed - needs Matcha Pro"
    end
    block.last = now
end

--====================================================================
-- MAIN LOOP
--====================================================================
local function onFrame()
    if _G.AlanHubGen ~= GEN then return end
    local active = isrbxactive()

    pcall(spectateFrame, active)
    pcall(espFrame)
    pcall(updateLootTimers)
    pcall(manaFrame, active)
    pcall(blockFrame, active)
    if tick() >= block.pushNext then
        block.pushNext = tick() + 1
        setField("rl_block_status", block.status)
    end
end

local frameConn = safeConnect(RunService, "RenderStepped", onFrame)
    or safeConnect(RunService, "Heartbeat", onFrame)
    or safeConnect(RunService, "Stepped", onFrame)

if not frameConn then
    task.spawn(function()
        while _G.AlanHubGen == GEN do
            onFrame()
            task.wait()
        end
    end)
end

local SCAN_INTERVAL = 2
task.spawn(function()
    while _G.AlanHubGen == GEN do
        task.wait(SCAN_INTERVAL)
        if _G.AlanHubGen ~= GEN then break end
        if ui("esp_enabled") then pcall(scanTrinkets) end
    end
end)

--====================================================================
-- CLEANUP (re-running the script calls this first)
--====================================================================
local function cleanup()
    _G.AlanHubGen = nil
    pcall(function() frameConn:Disconnect() end)
    pcall(memRestore)
    target = nil
    for _, e in ipairs(espList) do pcall(removeEsp, e) end
    espList = {}
    for _, n in ipairs(notifs) do pcall(removeNotif, n) end
    notifs = {}
    for _, c in ipairs(blockConns) do pcall(function() c:Disconnect() end) end
    pcall(UI.RemoveTab, TAB_NAME)
end

_G.AlanHub = { cleanup = cleanup, stop = stopSpectate }
