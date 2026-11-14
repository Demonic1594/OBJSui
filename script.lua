--normal
-- ============================================================
-- OJBS Suite — single-file application
-- ============================================================
if getgenv().OJBS_App_Cleanup then pcall(getgenv().OJBS_App_Cleanup) end
print("[OJBS-app] init")

-- ================================================================
-- 1. BOOTSTRAP & SERVICES
-- ================================================================
local OJBS_URL = "https://raw.githubusercontent.com/Demonic1594/OJBSui/main/ojbs_ui.lua"
local okLib, OJBS = pcall(function()
    return loadstring(game:HttpGet(OJBS_URL .. "?v=" .. tostring(os.time())))()
end)
if not okLib or not OJBS then
    error("[OJBS-app] could not load UI library: " .. tostring(OJBS))
end
if type(getgenv().OJBS_Cleanup) ~= "function" then
    warn("[OJBS-app] UI lib did not register getgenv().OJBS_Cleanup; heartbeat watchdog may misfire")
end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local Workspace         = game:GetService("Workspace")

local LP = Players.LocalPlayer
local Mouse = LP:GetMouse()

-- ================================================================
-- 2. CONSTANTS & CONFIG
-- ================================================================
local USE_EMOJI = true
local MAX_TICK = 800
local MAX_INFLIGHT = 128
local IS_MOBILE = UIS.TouchEnabled and not UIS.MouseEnabled

local AL_PREFIX = "AwakenedLimitless"  

local STATE_FILE = "OJBS_STATE_" .. tostring(game.PlaceId) .. ".json"
local LIB_FILE = "OJBS_LIB.json"

local DEFAULT_REMOTES = {
    skill  = "ReplicatedStorage.NetworkComm.SkillService.StartSkilll_Method",
    damage = "ReplicatedStorage.NetworkComm.CombatService.DamageCharacter_Method",
}

-- Remote reminder timing (seconds)
local REMOTE_REMINDER_GRACE    = 5    
local REMOTE_REMINDER_CHECK    = 2.5  
local REMOTE_REMINDER_INTERVAL = 15   

-- ================================================================
-- 3. FORWARD DECLARATIONS (shared across sections)
-- ================================================================
local CONNS = {}
local function track(c) CONNS[#CONNS + 1] = c; return c end

local Capture = { list = {}, byId = {} }
local refreshCapture = function() end

local _refreshLib = nil
local _refreshListenStatus = nil
local _rebuildMovesList = nil
local openLibDetail = nil

local _remoteReminderToken = 0
local _statusLoopToken = 0
local OWN_FIRE_MARK = {}

local M1
local snapshotSlot

local STATE = {
    restoreEnabled = true,
    remotes = { skill = DEFAULT_REMOTES.skill, damage = DEFAULT_REMOTES.damage },
    slots = {},
    captureAll = false,
    remoteReminders = true,
}

local LIB = { entries = {}, byId = {} }

-- ================================================================
-- 4. PERSISTENCE
-- ================================================================
local function loadState()
    local ok, data = pcall(function()
        if not (isfile and isfile(STATE_FILE)) then return nil end
        return HttpService:JSONDecode(readfile(STATE_FILE))
    end)
    if not ok or type(data) ~= "table" then return end
    if type(data.restoreEnabled) == "boolean" then STATE.restoreEnabled = data.restoreEnabled end
    if type(data.remotes) == "table" then
        if type(data.remotes.skill)  == "string" and data.remotes.skill  ~= "" then STATE.remotes.skill  = data.remotes.skill  end
        if type(data.remotes.damage) == "string" and data.remotes.damage ~= "" then STATE.remotes.damage = data.remotes.damage end
    end
    if type(data.slots) == "table" then STATE.slots = data.slots end
    if type(data.captureAll) == "boolean" then STATE.captureAll = data.captureAll end
    if type(data.remoteReminders) == "boolean" then STATE.remoteReminders = data.remoteReminders end
    if type(data.moves) == "table" then STATE.moves = data.moves end
end

local function writeState()
    local ok, err = pcall(function()
        if not writefile then error("no file api") end
        local out = {
            restoreEnabled = STATE.restoreEnabled,
            remotes = STATE.remotes,
            slots = {},
            captureAll = STATE.captureAll,
            remoteReminders = STATE.remoteReminders ~= false,
            moves = { rate = M1.moves.rate, list = {} },
        }
        for k, s in pairs(M1.slots) do out.slots[k] = snapshotSlot(s) end
        for i, mv in ipairs(M1.moves.list) do
            out.moves.list[i] = { name = mv.name, on = mv.on ~= false }
        end
        writefile(STATE_FILE, HttpService:JSONEncode(out))
    end)
    return ok, err
end

local stateToken = 0
local function saveState(deferred)
    stateToken += 1
    if not deferred then return writeState() end
    local t = stateToken
    task.delay(0.5, function()
        if t == stateToken then
            local ok, err = writeState()
            if not ok then warn("[OJBS] deferred save failed: " .. tostring(err)) end
        end
    end)
    return true
end

local function libReadAll()
    local ok, data = pcall(function()
        if not (isfile and isfile(LIB_FILE)) then return {} end
        local d = HttpService:JSONDecode(readfile(LIB_FILE))
        if type(d) == "table" then return d end
        return {}
    end)
    if ok and type(data) == "table" then return data end
    return {}
end

local libToken = 0
local function libSave(deferred)
    libToken += 1
    local t = libToken
    local function commit()
        local data = libReadAll()
        local out = {}
        for _, e in ipairs(LIB.entries) do
            out[#out + 1] = { id = e.id, name = e.name, rate = e.slot.rate, size = e.slot.size,
                origin = e.slot.origin, argMode = e.slot.argMode, useDamage = e.slot.useDamage }
        end
        data[tostring(game.PlaceId)] = out
        pcall(function() writefile(LIB_FILE, HttpService:JSONEncode(data)) end)
    end
    if not deferred then return commit() end
    task.delay(0.8, function() if t == libToken then commit() end end)
end

-- ================================================================
-- 5. UTILITIES
-- ================================================================
local function remoteAlive(r)
    return r ~= nil and r.Parent ~= nil
end

local function rootOf(m)
    if not m then return nil end
    if m:IsA("BasePart") then return m end
    return m:FindFirstChild("HumanoidRootPart")
        or m:FindFirstChild("RootPart")
        or m:FindFirstChild("Root")
        or m:FindFirstChild("Torso")
        or m:FindFirstChild("UpperTorso")
        or m:FindFirstChild("LowerTorso")
        or m:FindFirstChild("Head")
        or m:FindFirstChildWhichIsA("BasePart")
end

local function playersFolder()
    local c = Workspace:FindFirstChild("Characters")
    local s = c and c:FindFirstChild("Server")
    return s and s:FindFirstChild("Players")
end

local function npcsFolder()
    local c = Workspace:FindFirstChild("Characters")
    local s = c and c:FindFirstChild("Server")
    return s and s:FindFirstChild("NPCs")
end

local function newRayParams()
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude or Enum.RaycastFilterType.Blacklist
    return rp
end

local function makeNote(page, initialText)
    local row = page:Note(initialText or "")
    local lbl = row:FindFirstChildWhichIsA("TextLabel")
    return {
        instance = row,
        setText  = function(t) if lbl then lbl.Text = tostring(t or "") end end,
        getText  = function() return lbl and lbl.Text or "" end,
    }
end

local function resolvePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local node = game
    for part in string.gmatch(path, "[^%.]+") do
        if not node then return nil end
        node = node:FindFirstChild(part)
        if not node then return nil end
    end
    return node
end

local function resolvePlayerFromHit(hit)
    if not hit then return nil end
    local f = playersFolder()
    local m = hit
    while m and m.Parent do
        if m.Parent == f then return m end
        m = m.Parent
    end
    return nil
end

local function pickInstanceAt(px, py)
    if Mouse and Mouse.Target then
        return Mouse.Target
    end
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local rp = newRayParams()
    local ray = cam:ViewportPointToRay(px, py)
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 5000, rp)
    return hit and hit.Instance
end

local function aimPointAt(px, py)
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local rp = newRayParams()
    local filter = {}
    if LP.Character then filter[#filter + 1] = LP.Character end
    rp.FilterDescendantsInstances = filter
    local ray = cam:ViewportPointToRay(px, py)
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 5000, rp)
    return hit and hit.Position or (ray.Origin + ray.Direction * 400)
end

-- ================================================================
-- 6. SELF-TARGET DETECTION
-- ================================================================
local _cachedSelfModel = nil
local _cachedSelfAt = 0
local SELF_CACHE_TTL = 3
local _selfMissAt = 0
local SELF_MISS_TTL = 0.5

local function matchesPlayerName(modelName, pn)
    if not (type(modelName) == "string" and type(pn) == "string") or pn == "" then return false end
    if modelName == pn or modelName == pn .. "_Server" then return true end
    local pre = pn .. "_"
    return string.sub(modelName, 1, #pre) == pre
end

local function _isValidModel(m)
    return m ~= nil and m.Parent ~= nil and rootOf(m) ~= nil
end

local function _cacheSelf(m)
    _cachedSelfModel = m
    _cachedSelfAt = os.clock()
    return m
end

local function findOwnModelImpl()
    local pc = LP.Character
    if pc and pc.Parent and rootOf(pc) then return pc, "character" end

    local f = playersFolder()
    if f then
        local names = { LP.Name, LP.Name .. "_Server", LP.DisplayName, LP.DisplayName .. "_Server" }
        for _, name in ipairs(names) do
            if name and name ~= "" then
                local m = f:FindFirstChild(name)
                if _isValidModel(m) then return m, "name:" .. name end
            end
        end

        for _, c in ipairs(f:GetChildren()) do
            if c:IsA("Model") and _isValidModel(c) then
                local nn, dn = LP.Name, LP.DisplayName
                if matchesPlayerName(c.Name, nn) or matchesPlayerName(c.Name, dn) then
                    return c, "prefix:" .. c.Name
                end
            end
        end

        for _, c in ipairs(f:GetChildren()) do
            if c:IsA("Model") and _isValidModel(c) then
                local hum = c:FindFirstChildWhichIsA("Humanoid")
                if hum then
                    local dname = hum.DisplayName
                    if dname == LP.DisplayName or dname == LP.Name then
                        return c, "humanoid-displayname:" .. tostring(dname)
                    end
                    local okP, ref = pcall(function()
                        return hum:GetAttribute("Player")
                            or c:GetAttribute("Player")
                            or c:GetAttribute("Owner")
                            or c:GetAttribute("UserId")
                    end)
                    if okP and ref ~= nil
                       and (ref == LP or ref == LP.UserId or ref == LP.Name) then
                        return c, "humanoid-attr"
                    end
                end
            end
        end

        local cam = Workspace.CurrentCamera
        if cam then
            local vp = cam.ViewportSize
            local rp = newRayParams()
            local samples = {
                Vector2.new(vp.X * 0.5, vp.Y * 0.5),
                Vector2.new(vp.X * 0.5, vp.Y * 0.35),
                Vector2.new(vp.X * 0.5, vp.Y * 0.65),
                Vector2.new(vp.X * 0.5, vp.Y * 0.8),
            }
            for _, sp in ipairs(samples) do
                local ray = cam:ViewportPointToRay(sp.X, sp.Y)
                local hit = Workspace:Raycast(ray.Origin, ray.Direction * 250, rp)
                if hit then
                    local m = hit.Instance
                    while m and m.Parent do
                        if m.Parent == f then
                            if _isValidModel(m) then return m, "camera-ray" end
                            break
                        end
                        m = m.Parent
                    end
                end
            end

            local camPos = cam.CFrame.Position
            local look = cam.CFrame.LookVector
            local samples3d = {
                camPos + look * 5,
                camPos + look * 10,
                camPos + look * 15,
                camPos + Vector3.new(0, -10, 0),
                camPos,
            }
            for _, sample in ipairs(samples3d) do
                local best, bestDist
                for _, c in ipairs(f:GetChildren()) do
                    if c:IsA("Model") and _isValidModel(c) and c ~= pc then
                        local r = rootOf(c)
                        local d = (r.Position - sample).Magnitude
                        if d < 10 and (not bestDist or d < bestDist) then best, bestDist = c, d end
                    end
                end
                if best then return best, "camera-position" end
            end

            local best, bestDist
            for _, c in ipairs(f:GetChildren()) do
                if c:IsA("Model") and _isValidModel(c) and c ~= pc then
                    local r = rootOf(c)
                    local d = (r.Position - camPos).Magnitude
                    if d < 30 and (not bestDist or d < bestDist) then best, bestDist = c, d end
                end
            end
            if best then return best, "camera-nearest" end
        end

        local all = {}
        for _, c in ipairs(f:GetChildren()) do
            if c:IsA("Model") and _isValidModel(c) then all[#all + 1] = c end
        end
        if #all == 1 then return all[1], "only-one-in-folder" end
    end

    local cam = Workspace.CurrentCamera
    if cam then
        local camPos = cam.CFrame.Position
        local best, bestDist
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("Model") and desc:FindFirstChildWhichIsA("Humanoid") and desc ~= pc then
                local r = rootOf(desc)
                if r then
                    local d = (r.Position - camPos).Magnitude
                    if d < 20 and (not bestDist or d < bestDist) then best, bestDist = desc, d end
                end
            end
        end
        if best then return best, "workspace-nearest-humanoid" end
    end

    if pc and pc.Parent then return pc, "character-no-root" end
    return nil, "none"
end

local function findOwnModel()
    if _cachedSelfModel and _cachedSelfModel.Parent
       and (os.clock() - _cachedSelfAt) < SELF_CACHE_TTL
       and rootOf(_cachedSelfModel) then
        return _cachedSelfModel, "cache"
    end
    if _selfMissAt > 0 and (os.clock() - _selfMissAt) < SELF_MISS_TTL then
        return nil, "negative-cache"
    end
    local m, method = findOwnModelImpl()
    if m then
        _cacheSelf(m)
    else
        _selfMissAt = os.clock()
    end
    return m, method
end

if LP.CharacterAdded then
    LP.CharacterAdded:Connect(function()
        _cachedSelfModel, _cachedSelfAt, _selfMissAt = nil, 0, 0
    end)
    LP.CharacterRemoving:Connect(function()
        _cachedSelfModel, _cachedSelfAt, _selfMissAt = nil, 0, 0
    end)
end

local function isOwnModel(m)
    if not m then return false end
    if m == LP.Character then return true end
    if m == _cachedSelfModel then return true end
    local f = playersFolder()
    if f and m.Parent == f then
        if matchesPlayerName(m.Name, LP.Name) then return true end
    end
    return false
end

local function slotTargetLabel(slot)
    if not slot.target then return "Click torso · select player" end
    local name = slot.target.Name
    if isOwnModel(slot.target) then
        return "Target: " .. name .. " (you)"
    end
    return "Target: " .. name
end

-- ================================================================
-- 7. SLOT MODEL
-- ================================================================
M1 = {
    slots = {},
    moves = { list = {}, enabled = false, rate = 30, idx = 0, acc = 0, inflight = 0, at = 0 },
    npcs = {}, npcsAt = 0,
}

local function newSlot(cfg)
    return {
        target = nil, box = nil, enabled = false,
        rate    = cfg.rate    or 30,
        size    = cfg.size    or 160,
        alpha   = cfg.alpha   or 0.75,
        color   = cfg.color   or Color3.fromRGB(255, 60, 60),
        skill   = cfg.skill   or "Punch",
        origin  = cfg.origin  or "Target (ground)",
        argMode = cfg.argMode or "none",
        useDamage = cfg.useDamage ~= false,
        idx = 0, acc = 0, inflight = 0, at = 0,
    }
end

M1.slots.punch = newSlot({ skill = "Punch", rate = 50, size = 200, argMode = "1,1" })
M1.slots.burst = newSlot({ skill = "AwakenedLimitlessReversalBurst", rate = 40, size = 140, argMode = "none", color = Color3.fromRGB(255, 120, 60) })
M1.slots.nuke  = newSlot({ skill = "AwakenedLimitlessHollowNuke", rate = 60, size = 90, argMode = "targets", color = Color3.fromRGB(255, 170, 60) })

snapshotSlot = function(s)
    local tn
    if s.target then
        if isOwnModel(s.target) then tn = "__self__" else tn = s.target.Name end
    end
    return {
        rate = s.rate, size = s.size, alpha = s.alpha,
        color = { math.round(s.color.R * 255), math.round(s.color.G * 255), math.round(s.color.B * 255) },
        skill = s.skill, origin = s.origin, argMode = s.argMode,
        useDamage = s.useDamage, enabled = s.enabled,
        targetName = tn,
    }
end

local SLOT_ORIGINS  = { "Target (ground)", "Target", "Self (ground)", "Self" }
local SLOT_ARGMODES = { "targets", "none", "1,1" }
local function inList(v, list)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function applySlotState(key, saved)
    local s = M1.slots[key]
    if not s or type(saved) ~= "table" then return end
    if tonumber(saved.rate)  then s.rate  = tonumber(saved.rate)  end
    if tonumber(saved.size)  then s.size  = tonumber(saved.size)  end
    if tonumber(saved.alpha) then s.alpha = tonumber(saved.alpha) end
    if type(saved.color) == "table" then
        local r, g, b = tonumber(saved.color[1]), tonumber(saved.color[2]), tonumber(saved.color[3])
        if r and g and b then
            s.color = Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
        end
    end
    if type(saved.skill) == "string" and saved.skill ~= "" then s.skill = saved.skill end
    if type(saved.origin)  == "string" and inList(saved.origin,  SLOT_ORIGINS)  then s.origin  = saved.origin  end
    if type(saved.argMode) == "string" and inList(saved.argMode, SLOT_ARGMODES) then s.argMode = saved.argMode end
    s.useDamage = saved.useDamage ~= false

    if saved.enabled and STATE.restoreEnabled then
        s.enabled = true
        local restored = false
        if saved.targetName == "__self__" then
            local m, method = findOwnModel()
            if m then
                s.target = m
                restored = true
                print("[OJBS] restore '" .. tostring(key) .. "': self via " .. tostring(method))
            end
        elseif type(saved.targetName) == "string" then
            local f = playersFolder()
            local m = f and f:FindFirstChild(saved.targetName)
            if m and rootOf(m) then s.target = m; restored = true end
        end
        if not restored then
            local m, method = findOwnModel()
            s.target = m
            if m then
                print("[OJBS] restore '" .. tostring(key) .. "': fell back to self via " .. tostring(method))
            else
                warn("[OJBS] restore '" .. tostring(key) .. "': NO target found")
            end
        end
    end
end

local SkillRemote, DamageRemote
local function rebindRemotes(silent)
    SkillRemote  = resolvePath(STATE.remotes.skill)
    DamageRemote = resolvePath(STATE.remotes.damage)
    if not silent then
        local sm = remoteAlive(SkillRemote) and "ok" or "not found"
        local dm = remoteAlive(DamageRemote) and "ok" or "not found"
        OJBS:Notify("remotes: skill=" .. sm .. " · damage=" .. dm,
            (remoteAlive(SkillRemote) and remoteAlive(DamageRemote)) and Color3.fromRGB(64, 152, 255) or Color3.fromRGB(255, 110, 110))
    end
end

local function startRemoteReminder()
    _remoteReminderToken += 1
    local myToken = _remoteReminderToken
    task.spawn(function()
        task.wait(REMOTE_REMINDER_GRACE)
        local lastRemindAt = 0
        local reminded = false
        while _remoteReminderToken == myToken do
            local resolved = remoteAlive(SkillRemote) and remoteAlive(DamageRemote)
            if not resolved then
                rebindRemotes(true)
                resolved = remoteAlive(SkillRemote) and remoteAlive(DamageRemote)
            end
            if resolved then
                if reminded then
                    pcall(function()
                        OJBS:Notify("remotes resolved · ready to fire", Color3.fromRGB(64, 152, 255))
                    end)
                    print("[OJBS] remote reminder: resolved")
                    reminded = false
                end
                lastRemindAt = 0
            else
                local now = tick()
                if now - lastRemindAt >= REMOTE_REMINDER_INTERVAL then
                    lastRemindAt = now
                    reminded = true
                    local missing = {}
                    if not remoteAlive(SkillRemote) then missing[#missing + 1] = "skill" end
                    if not remoteAlive(DamageRemote) then missing[#missing + 1] = "damage" end
                    pcall(function()
                        OJBS:Notify(
                            "remotes missing: " .. table.concat(missing, " + ") .. " — Config → Rebind",
                            Color3.fromRGB(255, 110, 110)
                        )
                    end)
                    warn("[OJBS] remote reminder: skill=" ..
                        tostring(remoteAlive(SkillRemote)) ..
                        " damage=" .. tostring(remoteAlive(DamageRemote)) ..
                        " — open Config → Rebind remotes now")
                end
            end
            task.wait(REMOTE_REMINDER_CHECK)
        end
    end)
end

local function addToLib(id, name)
    local e = LIB.byId[id]
    if e then
        OJBS:Notify("already in library", Color3.fromRGB(255, 110, 110))
        return e
    end
    local slot = newSlot({ skill = id, rate = 30, size = 140, argMode = "targets",
        useDamage = true, color = Color3.fromRGB(255, 196, 92) })
    e = { id = id, name = name or id, slot = slot, search = string.lower((name or id) .. " " .. id) }
    LIB.entries[#LIB.entries + 1] = e
    LIB.byId[id] = e
    M1.slots["lib:" .. id] = slot

    if STATE.slots["lib:" .. id] then
        pcall(applySlotState, "lib:" .. id, STATE.slots["lib:" .. id])
    end
    if not slot.target then
        local m = findOwnModel()
        if m then slot.target = m end
    end

    libSave(true)
    saveState(true)
    OJBS:Notify("saved " .. e.name, Color3.fromRGB(64, 152, 255))

    if _refreshLib then _refreshLib() end
    refreshCapture()
    return e
end

local function removeFromLib(e)
    e.slot.enabled = false
    e.slot.acc, e.slot.idx, e.slot.inflight = 0, 0, 0
    if e.slot.box then pcall(function() e.slot.box:Destroy() end); e.slot.box = nil end
    M1.slots["lib:" .. e.id] = nil
    STATE.slots["lib:" .. e.id] = nil
    LIB.byId[e.id] = nil
    for i, x in ipairs(LIB.entries) do if x == e then table.remove(LIB.entries, i); break end end
    for _, c in ipairs(Capture.list) do if c.id == e.id then c.saved = false end end
    libSave(true)
    saveState(true)
    refreshCapture()
end

local function loadLibrary()
    local data = libReadAll()
    local list = data[tostring(game.PlaceId)]
    if type(list) ~= "table" then return end
    for _, rec in ipairs(list) do
        if type(rec) == "table" and type(rec.id) == "string" and not LIB.byId[rec.id] then
            local slot = newSlot({
                skill = rec.id, rate = tonumber(rec.rate) or 30, size = tonumber(rec.size) or 140,
                origin = rec.origin, argMode = rec.argMode or "targets",
                useDamage = rec.useDamage ~= false, color = Color3.fromRGB(255, 196, 92),
            })
            local name = rec.name or rec.id
            local e = { id = rec.id, name = name, slot = slot, search = string.lower(name .. " " .. rec.id) }
            LIB.entries[#LIB.entries + 1] = e
            LIB.byId[rec.id] = e
            M1.slots["lib:" .. rec.id] = slot
            if STATE.slots["lib:" .. rec.id] then
                pcall(applySlotState, "lib:" .. rec.id, STATE.slots["lib:" .. rec.id])
            end
            if not slot.target then
                local m = findOwnModel()
                if m then slot.target = m end
            end
        end
    end
end

loadState()

if type(STATE.moves) == "table" then
    if tonumber(STATE.moves.rate) then
        M1.moves.rate = math.max(1, math.floor(tonumber(STATE.moves.rate)))
    end
    if type(STATE.moves.list) == "table" then
        for _, mv in ipairs(STATE.moves.list) do
            if type(mv) == "table" and type(mv.name) == "string" and mv.name ~= "" then
                M1.moves.list[#M1.moves.list + 1] = { name = mv.name, on = mv.on ~= false }
            end
        end
    end
end

loadLibrary()
for _, key in ipairs({ "punch", "burst", "nuke" }) do
    if STATE.slots[key] then pcall(applySlotState, key, STATE.slots[key]) end
end
rebindRemotes(true)
print("[OJBS-app] state + library loaded")

if STATE.remoteReminders ~= false then
    startRemoteReminder()
end

task.spawn(function()
    for _ = 1, 30 do
        local m, method = findOwnModel()
        if m then
            local count = 0
            for _, slot in pairs(M1.slots) do
                if not slot.target or not slot.target.Parent then
                    slot.target = m
                    count += 1
                end
            end
            if count > 0 then
                print("[OJBS] default-to-self: assigned " .. count .. " slot(s) via " .. tostring(method))
                for _, slot in pairs(M1.slots) do
                    if slot._targetLabel and slot._targetLabel.Parent then
                        slot._targetLabel.Text = slotTargetLabel(slot)
                    end
                end
            end
            return
        end
        task.wait(0.5)
    end
    warn("[OJBS] default-to-self: could not find self after 15s")
end)

-- ================================================================
-- 8. SKILL LISTENER
-- ================================================================
local ListenOn = false
local hookState = { live = false, installed = false, err = nil, prev = nil }
local NAME_CACHE = {}
local _bumpHookStatus = nil

local DEBUG_HOOK = false
local function isServerCallMethod(m)
    if not m then return false end
    if m == "InvokeServer" or m == "FireServer" then return true end
    if m == "InvokeServerAsync" then return true end
    return false
end

local EXCLUDED = {
    Punch = true,
    AwakenedLimitlessReversalBurst = true,
}

local function skillDisplayName(id)
    if NAME_CACHE[id] then return NAME_CACHE[id] end
    local name
    local cfgs = ReplicatedStorage:FindFirstChild("Configs")
    if cfgs then
        local seen = {}
        local function walk(t, depth)
            if name or type(t) ~= "table" or depth > 4 or seen[t] then return end
            seen[t] = true
            for k, v in pairs(t) do
                if type(v) == "table" then
                    local nm = v.Name or v.DisplayName or v.SkillName
                    if type(nm) == "string" and (k == id or v.ID == id or v.Id == id or v.SkillID == id or v.SkillId == id) then
                        name = nm; return
                    end
                    walk(v, depth + 1)
                    if name then return end
                end
            end
        end
        for _, child in ipairs(cfgs:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                if ok and type(data) == "table" then
                    local hit = data[id]
                    if type(hit) == "table" then
                        local nm = hit.Name or hit.DisplayName or hit.SkillName
                        if type(nm) == "string" then name = nm end
                    end
                    if not name then walk(data, 0) end
                end
                if name then break end
            end
        end
    end
    if not name then
        name = id
        for _, pre in ipairs({ "AwakenedLimitless", "Awakened", "Limitless" }) do
            if string.sub(name, 1, #pre) == pre then name = string.sub(name, #pre + 1); break end
        end
    end
    NAME_CACHE[id] = name
    return name
end

local function recordSkill(id)
    if not ListenOn then return end
    if type(id) ~= "string" or id == "" or EXCLUDED[id] then return end
    if Capture.byId[id] then return end
    local e = { id = id, name = id, saved = LIB.byId[id] ~= nil }
    Capture.byId[id] = e
    Capture.list[#Capture.list + 1] = e
    refreshCapture()
    task.defer(function()
        e.name = skillDisplayName(id)
        refreshCapture()
        OJBS:Notify("caught " .. e.name, Color3.fromRGB(64, 152, 255))
    end)
end

local NOISY_REMOTE_PARTS = { "Chat", "Feedback", "Ignore", "Analytics", "SendMouse", "Teleport" }
local function isNoisyRemote(remote)
    if not remote then return true end
    local n = remote.Name
    if type(n) ~= "string" then return true end
    for _, p in ipairs(NOISY_REMOTE_PARTS) do
        if string.find(n, p, 1, true) then return true end
    end
    return false
end

local function installHook()
    if hookState.installed then return hookState.live end
    if not (hookmetamethod and getrawmetatable and getnamecallmethod) then
        hookState.err = "executor has no hookmetamethod"; return false
    end
    local ok, err = pcall(function()
        local prev
        prev = hookmetamethod(game, "__namecall", function(self, ...)
            if ListenOn then
                local okm, method = pcall(getnamecallmethod)
                if okm and isServerCallMethod(method) then
                    local remoteName = self ~= nil and self.Name or nil
                    local isSkillRemote = (self == SkillRemote) or (remoteName == "StartSkilll_Method")
                    local isOtherTarget = STATE.captureAll and not isNoisyRemote(self)

                    if isSkillRemote or isOtherTarget then
                        local args = { ... }
                        local a1 = args[1]

                        if DEBUG_HOOK then
                            print(string.format("[OJBS-hook] %s::%s  a1=%s:%s  a2=%s:%s  a3=%s:%s",
                                tostring(remoteName or "?"), tostring(method),
                                type(a1), tostring(a1),
                                type(args[2]), tostring(args[2]),
                                type(args[3]), tostring(args[3])))
                        end

                        if _bumpHookStatus then pcall(_bumpHookStatus, self, a1) end

                        local skillId = nil
                        for i = 1, math.min(#args, 4) do
                            if type(args[i]) == "string" and #args[i] > 0 then
                                skillId = args[i]; break
                            end
                        end

                        if skillId then
                            if isSkillRemote then
                                local isOurs = false
                                if type(checkcaller) == "function" then
                                    local cok, c = pcall(checkcaller)
                                    isOurs = cok and c or false
                                end
                                if not isOurs then
                                    local mark = OWN_FIRE_MARK[skillId]
                                    isOurs = mark ~= nil and os.clock() < mark
                                end
                                if not isOurs then task.defer(recordSkill, skillId) end
                            else
                                task.defer(recordSkill, skillId)
                            end
                        end
                    end
                end
            end
            return prev(self, ...)
        end)
        hookState.prev = prev
    end)
    if not ok then hookState.err = tostring(err); return false end
    hookState.installed = true
    hookState.live = true
    return true
end

local function uninstallHook()
    if not hookState.installed then return true end
    local prev = hookState.prev
    local restored = false
    if prev then
        restored = pcall(hookmetamethod, game, "__namecall", prev)
        if not restored and restorefunction then restored = pcall(restorefunction, prev) end
    end
    if not restored then hookState.err = "executor could not restore __namecall"; return false end
    hookState.prev = nil
    hookState.installed = false
    hookState.live = false
    hookState.err = nil
    return true
end

-- ================================================================
-- 9. M1 ENGINE
-- ================================================================
local pendingPick, pendingDest = nil, nil
local function armPick(cb, label)
    pendingPick = cb
    OJBS:Notify(label or "click a player", Color3.fromRGB(64, 152, 255))
end

local function scanNPCs()
    local now = os.clock()
    if now - M1.npcsAt < 0.15 and #M1.npcs > 0 then return M1.npcs end
    M1.npcsAt = now
    local out = {}
    local f = npcsFolder()
    if f then
        for _, m in ipairs(f:GetChildren()) do
            if m:IsA("Model") then
                local r = rootOf(m)
                if r then out[#out + 1] = { model = m, root = r } end
            end
        end
    end
    M1.npcs = out
    return out
end

local function castOrigin(slot, myChar, targets, target)
    local myRoot = rootOf(myChar)
    if not myRoot then return nil end
    local base = myRoot.Position
    local point = base
    if slot.origin ~= "Self" and slot.origin ~= "Self (ground)" then
        local pick = target
        if not pick then
            local bestD
            for _, t in ipairs(targets) do
                local r = rootOf(t)
                if r then
                    local d = (r.Position - base).Magnitude
                    if not bestD or d < bestD then pick, bestD = t, d end
                end
            end
        end
        local pr = pick and rootOf(pick)
        if pr then point = pr.Position end
    end
    if slot.origin == "Target (ground)" or slot.origin == "Self (ground)" then
        local rp = newRayParams()
        local filter = { myChar }
        if target then filter[#filter + 1] = target end
        rp.FilterDescendantsInstances = filter
        local hit = Workspace:Raycast(point + Vector3.new(0, 3, 0), Vector3.new(0, -150, 0), rp)
        if hit then point = hit.Position end
    end
    return point
end

local function ensureBox(slot, myChar, id)
    local r = rootOf(myChar)
    if not r then return end
    if not slot.box or not slot.box.Parent then
        slot.box = Instance.new("Part")
        slot.box.Name = "OJBS_Box_" .. tostring(id)
        slot.box.Anchored = true
        slot.box.CanCollide = false
        slot.box.CanQuery = false
        slot.box.CanTouch = false
        slot.box.CastShadow = false
        slot.box.Material = Enum.Material.ForceField
        slot.box.Parent = Workspace
    end
    slot.box.Size = Vector3.new(slot.size, slot.size, slot.size)
    slot.box.Transparency = slot.alpha
    slot.box.Color = slot.color
    slot.box.CFrame = CFrame.new(r.Position)
end

local _frameTargetsCache = {}

local function collectTargets(slot)
    local out = {}
    local myChar = slot.target
    if not myChar or not myChar.Parent then return out end
    local r = rootOf(myChar)
    if not r then return out end
    local key = tostring(myChar) .. "|" .. tostring(slot.size)
    local cached = _frameTargetsCache[key]
    if cached then return cached end
    local pos, h = r.Position, slot.size / 2
    for _, pair in ipairs(scanNPCs()) do
        local nr = pair.root
        if nr and nr.Parent then
            local d = nr.Position - pos
            if math.abs(d.X) <= h and math.abs(d.Y) <= h and math.abs(d.Z) <= h then
                out[#out + 1] = pair.model
            end
        end
    end
    _frameTargetsCache[key] = out
    return out
end

local function bump(group)
    local now = os.clock()
    if group.inflight >= MAX_INFLIGHT then
        if now - (group.at or 0) > 2 then group.inflight = 0 else return false end
    end
    group.inflight += 1
    group.at = now
    return true
end

local function fire(group, myChar, skillId, origin, targets, target, argMode, useDamage)
    if not remoteAlive(SkillRemote) then
        rebindRemotes(true)
        if not remoteAlive(SkillRemote) then return end
    end
    if not bump(group) then return end
    task.spawn(function()
        OWN_FIRE_MARK[skillId] = os.clock() + 2
        pcall(function()
            if argMode == "targets" then
                SkillRemote:InvokeServer(skillId, myChar, origin, {}, targets)
            elseif argMode == "1,1" then
                SkillRemote:InvokeServer(skillId, myChar, origin, {}, 1, 1)
            else
                SkillRemote:InvokeServer(skillId, myChar, origin, {})
            end
            if useDamage and target and remoteAlive(DamageRemote) then
                DamageRemote:InvokeServer({ target }, true, {
                    WindowID = myChar.Name .. "_" .. skillId,
                    LocalCharacter = myChar,
                    SkillID = skillId,
                })
            end
        end)
        group.inflight = math.max(0, group.inflight - 1)
    end)
end

local function runSlot(slot, dt)
    if not slot.enabled then
        slot.acc, slot.inflight = 0, 0
        if slot.box then slot.box:Destroy(); slot.box = nil end
        return
    end
    local myChar = slot.target
    if not myChar or not myChar.Parent then
        local m = findOwnModel()
        if m then
            myChar = m
            slot.target = m
            if slot._targetLabel and slot._targetLabel.Parent then
                slot._targetLabel.Text = slotTargetLabel(slot)
            end
        end
    end
    if not myChar or not myChar.Parent then
        if slot.box then slot.box:Destroy(); slot.box = nil end
        return
    end
    ensureBox(slot, myChar, slot.skill)
    slot.acc += dt * slot.rate
    local n = math.floor(slot.acc)
    if n <= 0 then return end
    slot.acc -= n
    if n > MAX_TICK then n = MAX_TICK end
    local targets = collectTargets(slot)
    if #targets == 0 then return end
    local originsCache = {}
    for _ = 1, n do
        slot.idx = slot.idx + 1
        local t = targets[(slot.idx - 1) % #targets + 1]
        local origin = originsCache[t]
        if not origin then
            origin = castOrigin(slot, myChar, targets, t)
            originsCache[t] = origin
        end
        if origin then fire(slot, myChar, slot.skill, origin, targets, t, slot.argMode, slot.useDamage) end
    end
end

local function runMoves(dt)
    if not M1.moves.enabled then M1.moves.acc, M1.moves.inflight = 0, 0; return end
    local base = M1.slots.punch
    local myChar = base.target
    if not myChar or not myChar.Parent then
        local m = findOwnModel()
        if m then myChar = m; base.target = m end
    end
    if not myChar or not myChar.Parent then return end
    M1.moves.acc += dt * M1.moves.rate
    local n = math.floor(M1.moves.acc)
    if n <= 0 then return end
    M1.moves.acc -= n
    if n > MAX_TICK then n = MAX_TICK end
    local targets = collectTargets(base)
    if #targets == 0 then return end
    local active = {}
    for _, mv in ipairs(M1.moves.list) do if mv.on then active[#active + 1] = mv end end
    if #active == 0 then return end
    local originsCache = {}
    for _ = 1, n do
        M1.moves.idx = M1.moves.idx + 1
        local mv = active[(M1.moves.idx - 1) % #active + 1]
        local t = targets[(M1.moves.idx - 1) % #targets + 1]
        local origin = originsCache[t]
        if not origin then
            origin = castOrigin(base, myChar, targets, t)
            originsCache[t] = origin
        end
        if origin then fire(M1.moves, myChar, AL_PREFIX .. mv.name, origin, targets, t, "targets", true) end
    end
end

-- ================================================================
-- 10. TELEPORT ENGINE
-- ================================================================
local TP = { root = nil, orig = nil, name = nil, dest = nil, running = false, interval = 0.1, acc = 0, lift = nil }
local function tpSay(msg, color) OJBS:Notify(msg, color) end

local function tpLock(model)
    local r = rootOf(model)
    if not r then tpSay("no root on " .. model.Name, Color3.fromRGB(255, 110, 110)) return end
    TP.root, TP.orig, TP.name, TP.lift = r, r.CFrame, model.Name, nil
    tpSay("locked " .. model.Name, Color3.fromRGB(157, 100, 255))
end

local function tpSetDest(p) TP.dest, TP.running, TP.acc, TP.lift = p, true, 0, nil; tpSay("teleport running", Color3.fromRGB(157, 100, 255)) end
local function tpToggle()
    if not TP.dest then tpSay("pick a spot first", Color3.fromRGB(255, 110, 110)) return end
    TP.running = not TP.running
    tpSay(TP.running and "teleport on" or "teleport paused", Color3.fromRGB(157, 100, 255))
end
local function tpReset()
    TP.running = false
    if TP.root and TP.root.Parent and TP.orig then
        TP.root.CFrame = TP.orig
        TP.root.AssemblyLinearVelocity = Vector3.zero
        TP.root.AssemblyAngularVelocity = Vector3.zero
    end
    TP.root, TP.orig, TP.name, TP.dest, TP.lift = nil, nil, nil, nil, nil
    tpSay("reset", Color3.fromRGB(157, 100, 255))
end

-- ================================================================
-- 11. UI CONSTRUCTION
-- ================================================================
print("[OJBS-app] building UI")

local m1Win = OJBS:CreateWindow({
    key = "m1", title = "M1 Box",
    icon = USE_EMOJI and "👊" or "M1",
    accent = Color3.fromRGB(64, 152, 255), offsetY = -36,
})

local tpWin = OJBS:CreateWindow({
    key = "tp", title = "Teleport",
    icon = USE_EMOJI and "🌀" or "TP",
    accent = Color3.fromRGB(157, 100, 255), offsetY = 36,
})

local function assignSelfTarget(slot, hostWin, selBtn, reason)
    local m, method = findOwnModel()
    if m then
        slot.target = m
        if selBtn then selBtn.Text = slotTargetLabel(slot) end
        if hostWin then hostWin:Status("target = self (" .. tostring(method) .. ")") end
        print("[OJBS] " .. tostring(reason or "assign self") .. ": " .. tostring(m.Name) .. " via " .. tostring(method))
        saveState(true)
        return m, method
    end
    if hostWin then hostWin:Status("could not find self model") end
    warn("[OJBS] " .. tostring(reason or "assign self") .. ": findOwnModel returned nil.")
    return nil, "none"
end

local function diagnoseSelf()
    print("========== [OJBS] SELF DIAGNOSTIC ==========")
    print("LP.Name:", LP.Name)
    print("LP.DisplayName:", LP.DisplayName)
    print("LP.UserId:", LP.UserId)
    print("LP.Character:", tostring(LP.Character))
    if LP.Character then
        print("  .Parent:", tostring(LP.Character.Parent))
        print("  rootOf():", tostring(rootOf(LP.Character)))
    end
    local f = playersFolder()
    print("playersFolder:", tostring(f and f:GetFullName() or "nil"))
    if f then
        print("  children:")
        for _, c in ipairs(f:GetChildren()) do
            local hum = c:FindFirstChildWhichIsA("Humanoid")
            local r = rootOf(c)
            print(string.format("    [%s] class=%s root=%s humanoid=%s dname=%s",
                c.Name, c.ClassName, tostring(r), tostring(hum), hum and tostring(hum.DisplayName) or "nil"))
        end
    end
    local cam = Workspace.CurrentCamera
    if cam then print("Camera.CFrame.Position:", tostring(cam.CFrame.Position)) end
    local m, method = findOwnModel()
    print("findOwnModel:", tostring(m), "via", tostring(method))
    print("===========================================")
end

local function buildSlotControls(page, slot, opts)
    opts = opts or {}
    local hostWin = opts.window or m1Win

    page:Section("Target")
    local selBtn
    selBtn = page:Button {
        text = slotTargetLabel(slot),
        extraOutline = true,
        callback = function()
            armPick(function(m)
                slot.target = m
                selBtn.Text = slotTargetLabel(slot)
                hostWin:Status("locked " .. m.Name)
                if isOwnModel(m) then _cacheSelf(m) end
                saveState(true)
            end, "click a player")
        end,
    }
    slot._targetLabel = selBtn

    page:Button {
        text = "Use Self as target",
        callback = function()
            assignSelfTarget(slot, hostWin, selBtn, "Use Self")
        end,
    }

    page:Section("Firing")
    slot.ui = page:Toggle {
        text = "Enable", value = slot.enabled,
        callback = function(v)
            slot.enabled = v
            if v and (not slot.target or not slot.target.Parent) then
                assignSelfTarget(slot, hostWin, selBtn, "Enable auto-target")
            end
            if not v and slot.box then slot.box:Destroy(); slot.box = nil end
            saveState(true)
        end,
    }
    page:Slider { text = "Casts / sec", min = 1, max = 100000, step = 1, value = slot.rate,
        callback = function(v) slot.rate = v; saveState(true) end }
    page:Slider { text = "Box size", min = 1, max = 7500, step = 1, value = slot.size,
        callback = function(v) slot.size = v; saveState(true) end }
    page:Cycle { text = "Origin", options = SLOT_ORIGINS,
        value = slot.origin, callback = function(v) slot.origin = v; saveState(true) end }
    page:Cycle { text = "StartSkill args", options = SLOT_ARGMODES,
        value = slot.argMode, callback = function(v) slot.argMode = v; saveState(true) end }
    page:Toggle { text = "DamageCharacter", value = slot.useDamage,
        callback = function(v) slot.useDamage = v; saveState(true) end }
    if opts.skillInput then
        page:Input { text = "Skill ID", value = slot.skill,
            callback = function(v) if v ~= "" then slot.skill = v; saveState(true) end end }
    end
end

local pGuide  = m1Win:AddTab("Guide")
local pMain   = m1Win:AddTab("Main")
local pBurst  = m1Win:AddTab("Red Burst")
local pNuke   = m1Win:AddTab("Hollow Nuke")
local pMoves  = m1Win:AddTab("Moves")
local pListen = m1Win:AddTab("Listener")
local pLib    = m1Win:AddTab("Library")
local pDetail = m1Win:AddTab("Detail")
local pVisual = m1Win:AddTab("Visuals")
local pConfig = m1Win:AddTab("Config")
local pColorM = m1Win:AddTab("Settings")
m1Win:SelectTab(2)

local LIB_TAB_IDX = 7
local DETAIL_TAB_IDX = 8

do
    pGuide:Section("Quick start")
    pGuide:Note("Every slot defaults to targeting you. Enabling a slot without a target auto-assigns you. If you want to target another player, click the target button and pick them.")
    pGuide:Section("Targets")
    pGuide:Note("Auto-target uses LP.Character first, then scans the server folder by name/prefix/humanoid attributes, then falls back to camera-based detection.")
    pGuide:Section("Persistence")
    pGuide:Note("Rate, size, enabled state, target, and the Moves list all save. Enabled slots come back enabled, and their target is restored if that player is still in the server, otherwise it falls back to you.")
    pGuide:Section("Box size")
    pGuide:Note("Box size goes up to 7500 studs. Large sizes (1000+) make the hitbox cover the entire area around the target, which is very demanding at high cast rates. Start at 500 and step up only if you need to.")
    pGuide:Section("Cast rate ceiling")
    pGuide:Note("Combined cast rate above ~200/s across all slots will likely trigger a remote-flood kick. The 100,000 casts/sec slider is a hard ceiling, not a safe operating range. For Nuke specifically, the game's server appears to rate-limit aggressive use — set Nuke's rate to 5-10/s and let the game's own cooldown govern actual firing.")
    pGuide:Section("Remotes")
    pGuide:Note("If the skill remote fails to resolve at boot, you'll get periodic red toasts every 15s until it's resolved. The script retries the resolution every 2.5s in the background. Once resolved, the reminders stop automatically.")
end

buildSlotControls(pMain, M1.slots.punch, {})
buildSlotControls(pBurst, M1.slots.burst, { skillInput = true })
buildSlotControls(pNuke, M1.slots.nuke, { skillInput = true })

do
    pMoves:Section("Add move")
    local moveNameInput = pMoves:Input { text = "Move", placeholder = "HollowNuke" }
    pMoves:Button {
        text = "Add move",
        callback = function()
            local n = moveNameInput.get()
            if n == "" then return end
            if string.sub(n, 1, #AL_PREFIX) == AL_PREFIX then n = string.sub(n, #AL_PREFIX + 1) end
            if n == "" then
                OJBS:Notify("empty move name", Color3.fromRGB(255, 110, 110))
                return
            end
            table.insert(M1.moves.list, { name = n, on = true })
            moveNameInput.setSilent("")
            saveState(true)
            if _rebuildMovesList then _rebuildMovesList() end
        end,
    }

    pMoves:Section("Moves")
    pMoves:Note("Click a row to toggle it on/off.")

    local movesList
    _rebuildMovesList = function()
        if movesList then movesList.set(M1.moves.list) end
    end

    movesList = pMoves:List {
        height = 200, rowH = 32,
        text = function(mv) return (mv.on and "✓  " or "○  ") .. tostring(mv.name) end,
        paint = function(mv, row)
            row.TextColor3 = mv.on and Color3.fromRGB(140, 216, 255) or Color3.fromRGB(233, 237, 244)
        end,
        onRow = function(mv) mv.on = not mv.on; _rebuildMovesList(); saveState(true) end,
    }
    _rebuildMovesList()

    pMoves:Button { text = "Clear all moves", callback = function()
        M1.moves.list = {}
        saveState(true)
        _rebuildMovesList()
    end }

    pMoves:Section("Firing")
    M1.movesUI = pMoves:Toggle { text = "Enable moves", value = false,
        callback = function(v)
            M1.moves.enabled = v
            if v and (not M1.slots.punch.target or not M1.slots.punch.target.Parent) then
                assignSelfTarget(M1.slots.punch, m1Win, nil, "moves enable auto-target")
            end
        end }
    pMoves:Slider { text = "Casts / sec", min = 1, max = 100000, step = 1, value = M1.moves.rate,
        callback = function(v) M1.moves.rate = v; saveState(true) end }
end

local listenToggle, captureList, capCount
do
    pListen:Section("Capture")
    pListen:Note("Fired skills land here. Punch, burst and nuke are ignored.")

    local listenStatusNote = makeNote(pListen, "")

    _refreshListenStatus = function()
        local sm = SkillRemote
        if remoteAlive(sm) then
            listenStatusNote.setText("Skill remote: ✓ " .. sm:GetFullName())
        else
            listenStatusNote.setText("Skill remote: ✗ not resolved — use Config → Rebind")
        end
    end
    _refreshListenStatus()

    local hookFireCount = 0
    local hookLastSeen = "—"
    _bumpHookStatus = function(remote, arg)
        hookFireCount = hookFireCount + 1
        local rn = "?"
        if type(remote) == "string" then rn = remote
        elseif remote ~= nil and remote.Name then rn = remote.Name or tostring(remote)
        elseif remote and type(remote) == "table" and remote.Name then rn = tostring(remote.Name) end
        hookLastSeen = rn .. " → " .. tostring(arg)
    end
    local hookStatusNote = makeNote(pListen, "")
    _statusLoopToken += 1
    local statusToken = _statusLoopToken
    task.spawn(function()
        while _statusLoopToken == statusToken do
            task.wait(0.5)
            local inst = hookStatusNote.instance
            if not inst or not inst.Parent then break end
            if hookFireCount == 0 then
                hookStatusNote.setText("Hook: 0 calls seen (executor may not hook game-side namecalls)")
            else
                hookStatusNote.setText("Hook: " .. hookFireCount .. " calls · last: " .. hookLastSeen)
            end
        end
    end)

    listenToggle = pListen:Toggle {
        text = "Listen for new moves", value = false,
        callback = function(v)
            ListenOn = v
            if not v then
                if uninstallHook() then
                    OJBS:Notify("listener off · hook removed", Color3.fromRGB(146, 156, 173))
                else
                    OJBS:Notify("listener off · " .. tostring(hookState.err), Color3.fromRGB(255, 110, 110))
                end
                return
            end
            if installHook() then
                OJBS:Notify("listening", Color3.fromRGB(64, 152, 255))
                m1Win:Status("hook installed")
            else
                ListenOn = false
                listenToggle.setSilent(false)
                OJBS:Notify("hook failed: " .. tostring(hookState.err), Color3.fromRGB(255, 110, 110))
            end
        end,
    }

    pListen:Toggle {
        text = "Capture from all remotes (debug)", value = STATE.captureAll,
        callback = function(v) STATE.captureAll = v; saveState(true) end,
    }

    pListen:Toggle {
        text = "Debug: log every namecall to console", value = false,
        callback = function(v) DEBUG_HOOK = v end,
    }

    capCount = makeNote(pListen, "0 captured")

    refreshCapture = function()
        if capCount then
            local ok, err = pcall(function() capCount.setText(#Capture.list .. " captured") end)
            if not ok then warn("[OJBS] capture count refresh failed: " .. tostring(err)) end
        end
        if captureList then
            local ok, err = pcall(function() captureList.set(Capture.list) end)
            if not ok then warn("[OJBS] capture list refresh failed: " .. tostring(err)) end
            pcall(function() captureList.refresh() end)
        end
    end

    captureList = pListen:List {
        height = 168, rowH = 30,
        text = function(e) return (e.saved and "✓  " or "+  ") .. tostring(e.name) .. "   ·   " .. tostring(e.id) end,
        paint = function(e, row)
            row.TextColor3 = e.saved and Color3.fromRGB(140, 216, 255) or Color3.fromRGB(233, 237, 244)
        end,
        onRow = function(e)
            if LIB.byId[e.id] then
                if openLibDetail then openLibDetail(LIB.byId[e.id]) end
                return
            end
            addToLib(e.id, e.name)
            e.saved = true
            refreshCapture()
        end,
    }
    refreshCapture()

    pListen:Button {
        text = "Save all captured",
        callback = function()
            local n = 0
            for _, e in ipairs(Capture.list) do
                if not LIB.byId[e.id] then addToLib(e.id, e.name); e.saved = true; n += 1 end
            end
            refreshCapture()
            OJBS:Notify(n > 0 and ("saved " .. n .. " moves") or "nothing new to save",
                n > 0 and Color3.fromRGB(64, 152, 255) or Color3.fromRGB(255, 110, 110))
        end,
    }
    pListen:Button { text = "Clear captures", callback = function() Capture.list, Capture.byId = {}, {}; refreshCapture() end }
end

do
    pLib:Section("Saved moves")
    pLib:Note("Every captured move is saved here with its full state. New moves default to self-target. Click a row to edit its settings on the Detail tab.")

    local libSearchInput = pLib:Input {
        text = "Find", placeholder = "name or skill id",
        callback = function() if _refreshLib then _refreshLib() end end,
    }
    local libCount = makeNote(pLib, #LIB.entries .. " saved")

    local function filtered()
        local q = string.lower(libSearchInput.get() or "")
        local out = {}
        for _, e in ipairs(LIB.entries) do
            if q == "" or string.find(e.search, q, 1, true) then out[#out + 1] = e end
        end
        return out
    end

    local libList
    _refreshLib = function()
        if libList then libList.set(filtered()) end
        if libCount then libCount.setText(#LIB.entries .. " saved") end
    end

    libList = pLib:List {
        height = 260, rowH = 30,
        text = function(e) return tostring(e.name) .. "   ·   " .. tostring(e.id) end,
        onRow = function(e) if openLibDetail then openLibDetail(e) end end,
    }
    libList.set(filtered())

    pLib:Button { text = "Refresh list", callback = function() if _refreshLib then _refreshLib() end end }
end

local function clearPage(page)
    for _, c in ipairs(page.instance:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    page.instance:SetAttribute("order", 0)
end

openLibDetail = function(entry)
    clearPage(pDetail)
    pDetail:Section(entry.name)
    pDetail:Note(entry.id)
    buildSlotControls(pDetail, entry.slot, { window = m1Win })
    pDetail:Section("Manage")
    pDetail:Button {
        text = "Delete from library",
        callback = function()
            removeFromLib(entry)
            if _refreshLib then _refreshLib() end
            m1Win:SelectTab(LIB_TAB_IDX)
            OJBS:Notify("deleted " .. entry.name, Color3.fromRGB(255, 110, 110))
        end,
    }
    pDetail:Button { text = "Back to library", callback = function() m1Win:SelectTab(LIB_TAB_IDX) end }
    m1Win:SelectTab(DETAIL_TAB_IDX)
end

do pDetail:Note("Click a move on the Library tab to edit its settings here.") end

do
    pVisual:Slider { text = "Motion smoothing", min = 0.6, max = 2.4, step = 0.05, value = 1.4, callback = function(_) end }
    pVisual:Slider {
        text = "Box transparency", min = 0, max = 1, step = 0.05, value = 0.75,
        callback = function(v) for _, s in pairs(M1.slots) do s.alpha = v end; saveState(true) end,
    }
    pVisual:Section("Box colour")
    local swatchRow = Instance.new("Frame")
    swatchRow.Size = UDim2.new(1, 0, 0, IS_MOBILE and 30 or 26)
    swatchRow.BackgroundTransparency = 1
    swatchRow.Parent = pVisual.instance
    local SWATCHES = {
        Color3.fromRGB(255, 138, 32), Color3.fromRGB(255, 198, 92),
        Color3.fromRGB(64, 152, 255), Color3.fromRGB(140, 216, 255),
        Color3.fromRGB(157, 100, 255), Color3.fromRGB(208, 168, 255),
        Color3.fromRGB(120, 235, 150), Color3.fromRGB(255, 102, 133),
    }
    for i, c in ipairs(SWATCHES) do
        local s = Instance.new("TextButton")
        s.Position = UDim2.fromOffset((i - 1) * (IS_MOBILE and 32 or 26), 0)
        s.Size = UDim2.fromOffset(IS_MOBILE and 28 or 22, IS_MOBILE and 28 or 22)
        s.BackgroundColor3 = c
        s.BorderSizePixel = 0
        s.Text = ""
        s.AutoButtonColor = false
        s.Parent = swatchRow
        local ui = Instance.new("UICorner", s); ui.CornerRadius = UDim.new(0, 5)
        local stroke = Instance.new("UIStroke", s); stroke.Color = Color3.new(0,0,0); stroke.Thickness = 1.2
        s.MouseButton1Click:Connect(function()
            for _, slot in pairs(M1.slots) do
                slot.color = c
                if slot.box then slot.box.Color = c end
            end
            saveState(true)
        end)
    end
end

do
    pConfig:Section("Remotes")
    local skillIn = pConfig:Input { text = "Skill remote", value = STATE.remotes.skill }
    local damageIn = pConfig:Input { text = "Damage remote", value = STATE.remotes.damage }
    local statusNote = makeNote(pConfig, "")

    local function updateStatus()
        local s = SkillRemote
        local d = DamageRemote
        statusNote.setText("skill: " .. (remoteAlive(s) and "✓ resolved" or "✗ not found") ..
                          "   damage: " .. (remoteAlive(d) and "✓ resolved" or "✗ not found"))
        if _refreshListenStatus then _refreshListenStatus() end
    end
    updateStatus()

    pConfig:Button {
        text = "Rebind remotes now", extraOutline = true,
        callback = function()
            STATE.remotes.skill = skillIn.get()
            STATE.remotes.damage = damageIn.get()
            rebindRemotes(false)
            updateStatus()
            saveState(true)
            if STATE.remoteReminders ~= false then
                startRemoteReminder()
            end
        end,
    }
    pConfig:Button {
        text = "Reset to default paths",
        callback = function()
            STATE.remotes.skill = DEFAULT_REMOTES.skill
            STATE.remotes.damage = DEFAULT_REMOTES.damage
            skillIn.setSilent(STATE.remotes.skill)
            damageIn.setSilent(STATE.remotes.damage)
            rebindRemotes(true)
            updateStatus()
            saveState(true)
            if STATE.remoteReminders ~= false then
                startRemoteReminder()
            end
        end,
    }

    pConfig:Toggle {
        text = "Remind me when remotes unresolved", value = STATE.remoteReminders ~= false,
        callback = function(v)
            STATE.remoteReminders = v
            saveState(true)
            if v then
                startRemoteReminder()
            else
                _remoteReminderToken += 1
                print("[OJBS] remote reminder: silenced by user")
            end
        end,
    }
    pConfig:Note("When on, you'll get a red toast every 15s while the remotes can't resolve. The script retries resolution every 2.5s in the background.")

    pConfig:Section("Self detection")
    pConfig:Button {
        text = "Diagnose self target",
        callback = function()
            diagnoseSelf()
            OJBS:Notify("diagnostics printed to console", Color3.fromRGB(64, 152, 255))
        end,
    }
    pConfig:Button {
        text = "Force self on all slots",
        callback = function()
            local m, method = findOwnModel()
            if m then
                for _, slot in pairs(M1.slots) do
                    slot.target = m
                    if slot._targetLabel and slot._targetLabel.Parent then
                        slot._targetLabel.Text = slotTargetLabel(slot)
                    end
                end
                saveState(true)
                OJBS:Notify("all slots → self via " .. tostring(method), Color3.fromRGB(64, 152, 255))
            else
                OJBS:Notify("could not find self model", Color3.fromRGB(255, 110, 110))
                diagnoseSelf()
            end
        end,
    }

    pConfig:Section("Auto-restore")
    pConfig:Toggle {
        text = "Restore enabled on load", value = STATE.restoreEnabled,
        callback = function(v) STATE.restoreEnabled = v; saveState(true) end,
    }

    pConfig:Section("Manage")
    pConfig:Button {
        text = "Save state now",
        callback = function()
            local ok, err = writeState()
            OJBS:Notify(ok and "state saved" or ("save failed: " .. tostring(err)),
                ok and Color3.fromRGB(64, 152, 255) or Color3.fromRGB(255, 110, 110))
        end,
    }
    pConfig:Button {
        text = "Wipe saved slot config",
        callback = function()
            pcall(function() if delfile and isfile and isfile(STATE_FILE) then delfile(STATE_FILE) end end)
            STATE.slots = {}
            STATE.moves = nil
            OJBS:Notify("saved slot config wiped", Color3.fromRGB(255, 110, 110))
        end,
    }
    pConfig:Button {
        text = "Wipe saved library moves",
        callback = function()
            pcall(function() if delfile and isfile and isfile(LIB_FILE) then delfile(LIB_FILE) end end)
            for _, e in ipairs(LIB.entries) do
                M1.slots["lib:" .. e.id] = nil
                STATE.slots["lib:" .. e.id] = nil
                if e.slot.box then pcall(function() e.slot.box:Destroy() end) end
            end
            LIB.entries, LIB.byId = {}, {}
            if _refreshLib then _refreshLib() end
            OJBS:Notify("all library moves wiped", Color3.fromRGB(255, 110, 110))
        end,
    }
end

pColorM:ColorPicker()
pColorM:ThemeSaver()
pColorM:StyleTab()

local pTGuide = tpWin:AddTab("Guide")
local pTCtrl  = tpWin:AddTab("Control")
local pTSet   = tpWin:AddTab("Settings")
tpWin:SelectTab(2)

do
    pTGuide:Section("Quick start")
    pTGuide:Note("Open Control, press Click torso · select player, click your own torso, then click a spot on the ground. Set Interval and press Start.")
    pTGuide:Section("Controls")
    pTGuide:Note("H pauses/resumes. J resets.")
end

do
    pTCtrl:Section("Target")
    local tpNameInput = pTCtrl:Input { text = "Model", placeholder = "Name_Server" }
    pTCtrl:Button {
        text = "Lock by name",
        callback = function()
            local f = playersFolder()
            local m = f and f:FindFirstChild(tpNameInput.get())
            if not m then OJBS:Notify("no model named " .. tpNameInput.get(), Color3.fromRGB(255, 110, 110)) return end
            tpLock(m)
        end,
    }
    pTCtrl:Button { text = "Click torso · select player", extraOutline = true,
        callback = function() armPick(tpLock, "click a player") end }

    pTCtrl:Section("Destination")
    pTCtrl:Button {
        text = "Click ground spot",
        callback = function()
            if not TP.root then OJBS:Notify("lock a target first", Color3.fromRGB(255, 110, 110)) return end
            pendingDest = function(p) tpSetDest(p) end
            OJBS:Notify("click a spot", Color3.fromRGB(157, 100, 255))
        end,
    }
    pTCtrl:Button { text = "Start / stop (H)", callback = tpToggle }
    pTCtrl:Button { text = "Reset position (J)", callback = tpReset }
    pTCtrl:Slider { text = "Interval (s)", min = 0.02, max = 0.5, step = 0.01, value = 0.1,
        callback = function(v) TP.interval = v end }
end

pTSet:ColorPicker()
pTSet:ThemeSaver()
pTSet:StyleTab()
print("[OJBS-app] UI built")

-- ================================================================
-- 12. INPUT HANDLERS
-- ================================================================
track(UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.H then
        if not TP.root or not TP.root.Parent then armPick(tpLock, "click a player")
        elseif not TP.dest then pendingDest = function(p) tpSetDest(p) end
            OJBS:Notify("click a spot", Color3.fromRGB(157, 100, 255))
        else tpToggle() end
        return
    end
    if input.KeyCode == Enum.KeyCode.J then tpReset(); return end

    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        local px, py = input.Position.X, input.Position.Y
        if pendingDest then
            local p = aimPointAt(px, py)
            local cb = pendingDest
            pendingDest = nil
            if p then cb(p) end
            return
        end
        if pendingPick then
            local hit = pickInstanceAt(px, py)
            local m = resolvePlayerFromHit(hit)
            if not m then
                OJBS:Notify("not a player character", Color3.fromRGB(255, 110, 110))
                return
            end
            local cb = pendingPick
            pendingPick = nil
            if rootOf(m) then cb(m) else OJBS:Notify("no root on " .. m.Name, Color3.fromRGB(255, 110, 110)) end
        end
    end
end))

-- ================================================================
-- 13. HEARTBEAT
-- ================================================================
track(RunService.Heartbeat:Connect(function(dt)
    if not getgenv().OJBS_Cleanup then
        if getgenv().OJBS_App_Cleanup then pcall(getgenv().OJBS_App_Cleanup) end
        return
    end
    table.clear(_frameTargetsCache)
    if TP.running and TP.dest then
        TP.acc += dt
        if TP.acc >= TP.interval then
            TP.acc -= TP.interval
            if not TP.root or not TP.root.Parent then
                local f = playersFolder()
                local m = f and TP.name and f:FindFirstChild(TP.name)
                local r = m and rootOf(m)
                if r then TP.root = r else TP.running = false; tpSay("target gone", Color3.fromRGB(255, 110, 110)) end
            end
            if TP.root and TP.root.Parent and TP.dest then
                local model = TP.root.Parent
                if not TP.lift then
                    local minY, baseY = math.huge, TP.root.Position.Y
                    for _, d in ipairs(model:GetDescendants()) do
                        if d:IsA("BasePart") and d ~= TP.root then
                            local b = d.Position.Y - d.Size.Y * 0.5
                            if b < minY then minY = b end
                        end
                    end
                    TP.lift = (minY < math.huge) and math.clamp(baseY - minY, 0.5, 12) or 3
                end
                local rp = newRayParams()
                pcall(function() rp.RespectCanCollide = true end)
                local filter = { model }
                local mine = LP.Character
                if mine and mine ~= model then filter[#filter + 1] = mine end
                rp.FilterDescendantsInstances = filter
                local from = Vector3.new(TP.dest.X, TP.dest.Y + 10, TP.dest.Z)
                local ground = Workspace:Raycast(from, Vector3.new(0, -400, 0), rp)
                local y = ground and (ground.Position.Y + TP.lift) or TP.dest.Y
                local c = TP.root.CFrame
                TP.root.CFrame = CFrame.new(TP.dest.X, y, TP.dest.Z) * (c - c.Position)
                TP.root.AssemblyLinearVelocity = Vector3.zero
                TP.root.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end
    for _, slot in pairs(M1.slots) do runSlot(slot, dt) end
    runMoves(dt)
end))

task.defer(function()
    if not STATE.restoreEnabled then return end
    local names = {}
    for _, key in ipairs({ "punch", "burst", "nuke" }) do
        local s = M1.slots[key]
        if s and s.enabled then names[#names + 1] = key end
    end
    for key, s in pairs(M1.slots) do
        if string.sub(key, 1, 4) == "lib:" and s.enabled then names[#names + 1] = key:sub(5) end
    end
    if #names > 0 then
        if remoteAlive(SkillRemote) then
            OJBS:Notify("restored & firing: " .. table.concat(names, ", "), Color3.fromRGB(255, 110, 110))
        else
            OJBS:Notify("restored (waiting for remotes): " .. table.concat(names, ", "), Color3.fromRGB(255, 170, 60))
        end
    end
end)

OJBS:RailOpen(false)

-- ================================================================
-- 14. CLEANUP
-- ================================================================
local unloaded = false
local _cleanupWrapper 
local function doAppCleanup()
    if unloaded then return end
    unloaded = true
    _remoteReminderToken += 1 
    _statusLoopToken += 1   
    pcall(writeState)
    ListenOn = false
    pcall(uninstallHook)
    TP.running = false
    TP.dest = nil
    pendingPick, pendingDest = nil, nil
    M1.moves.enabled = false
    table.clear(OWN_FIRE_MARK)
    for _, slot in pairs(M1.slots) do
        slot.enabled = false
        slot.acc, slot.idx, slot.inflight = 0, 0, 0
        if slot.box then pcall(function() slot.box:Destroy() end); slot.box = nil end
    end
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    table.clear(CONNS)
    if getgenv().OJBS_App_Cleanup == _cleanupWrapper then getgenv().OJBS_App_Cleanup = nil end
    print("[OJBS-app] cleaned up")
end

_cleanupWrapper = function() pcall(doAppCleanup) end
getgenv().OJBS_App_Cleanup = _cleanupWrapper
print("[OJBS-app] ready")
