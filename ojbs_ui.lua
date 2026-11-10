--[[
============================================================
 OJBS UI — reusable widget module (Luau)
============================================================
 Load:
   local OJBS = loadstring(game:HttpGet("<raw url>/ojbs_ui.lua"))()

 Module
   OJBS:CreateWindow{ key, title, icon, accent, offsetY } -> Window
   OJBS:CreateRailButton(key, icon)   -- CreateWindow calls this for you
   OJBS:Notify(text, color?)
   OJBS:RailOpen(bool)
   OJBS:GetStyle() -> table
   OJBS:SetStyle(table)               -- also updates open StyleTab controls
   OJBS:Teardown()

 Window
   :AddTab(name) -> Page   :SelectTab(i)   :Status(text)
   :OnAccent(fn(color))    :Open()         :Close()     .instance

 Page
   :Section(text)  :Note(text)  :ColorPicker()  :ThemeSaver()  :StyleTab()
   :Toggle{text,value,callback}            -> handle
   :Slider{text,min,max,step,value,suffix,callback} -> handle
   :Input{text,placeholder,value,callback} -> handle
   :Cycle{text,options,value,callback}     -> handle
   :Button{text,callback,extraOutline}     -> TextButton
   :List{height,rowH,pool,text,paint,onRow}-> { set(items), refresh(), instance }

 Handle = { get(), set(v) [fires callback], setSilent(v), instance }

 Example
   local OJBS = loadstring(game:HttpGet(URL))()
   local win = OJBS:CreateWindow({ key = "main", title = "My App", icon = "⚙",
       accent = Color3.fromRGB(64, 152, 255) })
   local page = win:AddTab("Main")
   page:Section("Controls")
   local t = page:Toggle { text = "Enable", value = false, callback = function(v)
       win:Status("enabled: " .. tostring(v)) end }
   local s = page:Slider { text = "Rate", min = 1, max = 100, step = 1, value = 30,
       callback = function(v) end }
   page:Button { text = "Go", callback = function() OJBS:Notify("go!") end }
   page:Note("Press RightCtrl or tap the ⚙ to show the rail.")
   win:AddTab("Settings"):StyleTab()
   s.setSilent(50)        -- moves the slider without firing its callback
   OJBS:RailOpen(true)
   win:Open()
============================================================
]]

local genv = (type(getgenv) == "function" and getgenv()) or _G
if genv.OJBS_Cleanup then pcall(genv.OJBS_Cleanup) end

local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")
local Workspace    = game:GetService("Workspace")

local LP = Players.LocalPlayer

local TOGGLE_KEY = Enum.KeyCode.RightControl
local USE_EMOJI  = true

-- ---- MOBILE FLAGS --------------------------------------------------------
local IS_MOBILE  = UIS.TouchEnabled and not UIS.MouseEnabled
local WINDOW_W, WINDOW_H = IS_MOBILE and 340 or 600, IS_MOBILE and 420 or 442
local RAIL_W, RAIL_OFF  = IS_MOBILE and 46 or 58, IS_MOBILE and 10 or 24
local TAB_W             = IS_MOBILE and 74 or 84
local ROW_H             = IS_MOBILE and 40 or 36
local MOTION = 1.4

local FONT_MONO  = Enum.Font.Code
local FONT_TITLE = Enum.Font.Arcade

-- STYLE.bg is keyed by window key. Unknown keys render "classic".
-- TODO: the original defaulted its two built-in windows to "studs" and
-- "crt"; generic keys have no per-window default, so new windows start
-- as "classic" until the user picks a pattern.
local STYLE = {
    bg      = {},
    opacity = 0.55,
    scan    = true,
    glow    = true,
    round   = 4,
    outline = 1,
    scale   = 1,
}
local BG_KINDS = { "classic", "studs", "grid", "crt" }
-- Kept from the original. Nothing reads it there either ("Wipe saved
-- settings" only deletes the file).
local STYLE_DEFAULT = {
    bg      = {},
    opacity = 0.55,
    scan    = true,
    glow    = true,
    round   = 4,
    outline = 1,
    scale   = 1,
}
local _ = STYLE_DEFAULT

local BASE = {
    bg     = Color3.fromRGB(22, 25, 32),
    bg2    = Color3.fromRGB(27, 31, 39),
    panel  = Color3.fromRGB(35, 40, 50),
    panel2 = Color3.fromRGB(44, 50, 62),
    line   = Color3.fromRGB(56, 63, 77),
    text   = Color3.fromRGB(233, 237, 244),
    dim    = Color3.fromRGB(146, 156, 173),
    black  = Color3.fromRGB(0, 0, 0),
}

local WHITE = Color3.new(1, 1, 1)
local function lighten(c) return c:Lerp(WHITE, 0.35) end

-- Fallback accent for windows created without `accent`.
local DEFAULT_THEME = { a = Color3.fromRGB(64, 152, 255), b = Color3.fromRGB(140, 216, 255) }

-- Default accent per window key, filled in by CreateWindow.
local THEMES = {}

local SWATCHES = {
    Color3.fromRGB(255, 138, 32), Color3.fromRGB(255, 198, 92),
    Color3.fromRGB(64, 152, 255), Color3.fromRGB(140, 216, 255),
    Color3.fromRGB(157, 100, 255), Color3.fromRGB(208, 168, 255),
    Color3.fromRGB(120, 235, 150), Color3.fromRGB(255, 102, 133),
}

local RED = Color3.fromRGB(255, 110, 110)

local State = {
    open = nil,
    railOpen = false,
    colors = {},
}

-- Forward declarations used by closures defined earlier in the file
local refreshRailColors
local setRail
local setAccent, pushRGB
local doUnload
local applyAllStyles
local syncStyleControls
local refreshToggleTab

-- ---------------------------------------------------------------- helpers
local CONNS = {}
local function track(c) CONNS[#CONNS + 1] = c; return c end

local function inst(class, props, parent)
    local o = Instance.new(class)
    if props then
        for k, v in pairs(props) do
            if k ~= "Parent" then o[k] = v end
        end
    end
    if parent then o.Parent = parent end
    return o
end

local function clampRange(v, a, b)
    local lo, hi = math.min(a, b), math.max(a, b)
    return math.clamp(v, lo, hi)
end

local CORNERS, OUTLINES, HALOS = {}, {}, {}

local function corner(o, r)
    local px = math.min(r or 8, STYLE.round)
    local ui = inst("UICorner", { CornerRadius = UDim.new(0, px) }, o)
    CORNERS[#CORNERS + 1] = { ui = ui, r = r or 8 }
    return ui
end

local function outline(o, thick)
    local base = thick or 1.4
    local s = inst("UIStroke", {
        Color = BASE.black,
        Thickness = base * STYLE.outline,
        Transparency = 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, o)
    OUTLINES[#OUTLINES + 1] = { s = s, base = base }
    return s
end

local function accentStroke(o, color, thick, trans)
    local base = thick or 1
    local s = inst("UIStroke", {
        Color = color,
        Thickness = base * STYLE.outline,
        Transparency = trans or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, o)
    OUTLINES[#OUTLINES + 1] = { s = s, base = base }
    return s
end

local function pad(o, l, t, r, b)
    inst("UIPadding", {
        PaddingLeft   = UDim.new(0, l or 0),
        PaddingTop    = UDim.new(0, t or 0),
        PaddingRight  = UDim.new(0, r or 0),
        PaddingBottom = UDim.new(0, b or 0),
    }, o)
end

local function tw(o, t, props, style, dir)
    local tr = TweenService:Create(o, TweenInfo.new((t or 0.18) * MOTION, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
    tr:Play()
    return tr
end

local function gradient(o, a, b, rot)
    return inst("UIGradient", { Rotation = rot or 0, Color = ColorSequence.new(a, b) }, o)
end

local function halo(parent, color, radius, alpha)
    local g = inst("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = color,
        BackgroundTransparency = alpha or 0.85,
        BorderSizePixel = 0,
        Active = false,
        -- Widgets are now built after load, so honour the glow setting at
        -- creation instead of waiting for the next applyAllStyles().
        Visible = STYLE.glow,
    }, parent)
    inst("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, g)
    HALOS[#HALOS + 1] = g
    return g
end

local function nextOrder(page)
    local n = (page:GetAttribute("order") or 0) + 1
    page:SetAttribute("order", n)
    return n
end

local function safeCall(label, fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then warn("[OJBS] " .. label .. " error:", err) end
end

-- ---------------------------------------------------------------- backgrounds
local applyBackground, applyScan

do
    local function bgAlpha()
        return math.clamp(0.92 - 0.42 * STYLE.opacity, 0.12, 0.97)
    end

    local function clearLayer(layer)
        if not layer then return end
        for _, c in ipairs(layer:GetChildren()) do c:Destroy() end
    end

    local function buildStuds(layer)
        local pitch, size = 36, 22
        local alpha = bgAlpha()
        local base = Color3.fromRGB(52, 60, 76)
        local lit  = Color3.fromRGB(92, 104, 126)
        local rows = math.ceil(WINDOW_H / pitch)
        local cols = math.ceil(WINDOW_W / pitch) + 1
        for r = 0, rows - 1 do
            local shift = (r % 2 == 1) and pitch * 0.5 or 0
            for c = 0, cols - 1 do
                local s = inst("Frame", {
                    Position = UDim2.fromOffset(c * pitch + shift, r * pitch),
                    Size = UDim2.fromOffset(size, size),
                    BackgroundColor3 = base,
                    BackgroundTransparency = alpha,
                    BorderSizePixel = 0,
                    Active = false,
                }, layer)
                inst("UICorner", { CornerRadius = UDim.new(0, size / 2) }, s)
                inst("UIGradient", { Rotation = 45, Color = ColorSequence.new(lit, base) }, s)
                local dot = inst("Frame", {
                    Position = UDim2.fromOffset(5, 4),
                    Size = UDim2.fromOffset(size * 0.34, size * 0.34),
                    BackgroundColor3 = Color3.new(1, 1, 1),
                    BackgroundTransparency = math.clamp(alpha + 0.14, 0, 1),
                    BorderSizePixel = 0,
                    Active = false,
                }, s)
                inst("UICorner", { CornerRadius = UDim.new(0, size / 4) }, dot)
            end
        end
    end

    local function buildGrid(layer)
        local step = 32
        local alpha = math.clamp(bgAlpha() + 0.1, 0.3, 0.99)
        local col = Color3.fromRGB(124, 144, 176)
        for x = step, WINDOW_W, step do
            inst("Frame", {
                Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, 1, 1, 0),
                BackgroundColor3 = col, BackgroundTransparency = alpha, BorderSizePixel = 0, Active = false,
            }, layer)
        end
        for y = step, WINDOW_H, step do
            inst("Frame", {
                Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = col, BackgroundTransparency = alpha, BorderSizePixel = 0, Active = false,
            }, layer)
        end
    end

    local function scanFrame(parent, baseAlpha)
        local holder = inst("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Active = false,
        }, parent)
        local trans = math.clamp(baseAlpha, 0.5, 0.99)
        for y = 0, WINDOW_H - 1, 4 do
            inst("Frame", {
                Position = UDim2.fromOffset(0, y),
                Size = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = Color3.new(0, 0, 0),
                BackgroundTransparency = trans,
                BorderSizePixel = 0,
                Active = false,
            }, holder)
        end
        return holder
    end

    local function buildCRT(layer)
        scanFrame(layer, math.clamp(0.99 - 0.55 * STYLE.opacity, 0.7, 0.99))
        local vig = inst("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(0, 0, 0),
            BorderSizePixel = 0,
            Active = false,
        }, layer)
        inst("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new(Color3.new(0, 0, 0)),
            Transparency = NumberSequence.new({ 0.55, 1, 0.55 }),
        }, vig)
    end

    applyBackground = function(win, kind)
        local layer = win.bgLayer
        if not (layer and layer.Parent) then return end
        kind = kind or "classic"
        local sig = kind .. "@" .. string.format("%.3f", STYLE.opacity)
        if win.bgSig == sig then return end
        win.bgSig = sig
        win.bgKind = kind
        clearLayer(layer)
        if kind == "studs" then buildStuds(layer)
        elseif kind == "grid" then buildGrid(layer)
        elseif kind == "crt" then buildCRT(layer) end
    end

    applyScan = function(win, on)
        local layer = win.scanLayer
        if not (layer and layer.Parent) then return end
        local sig = on and "on" or "off"
        if win.scanSig == sig then return end
        win.scanSig = sig
        clearLayer(layer)
        if on then scanFrame(layer, 0.94) end
    end
end

-- ---------------------------------------------------------------- root gui
local gui = inst("ScreenGui", {
    Name = "OJBS",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 500,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
do
    local parent = nil
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then parent = hui end
    end
    if not parent then parent = LP:WaitForChild("PlayerGui") end
    gui.Parent = parent
end

local ROOT = inst("Frame", {
    Name = "Root",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Active = false,
}, gui)
local ROOT_SCALE = inst("UIScale", { Scale = 1 }, ROOT)
if IS_MOBILE then ROOT_SCALE.Scale = 1 end

local function viewport()
    local cam = Workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
    local inset = IS_MOBILE and 8 or 0
    return vp, inset
end

local WIN_CLASS = "CanvasGroup"
do
    local ok = pcall(function() local c = Instance.new("CanvasGroup"); c:Destroy() end)
    if not ok then WIN_CLASS = "Frame" end
end

-- ---------------------------------------------------------------- toast
local toast = inst("Frame", {
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -24),
    Size = UDim2.fromOffset(IS_MOBILE and 300 or 340, IS_MOBILE and 44 or 40),
    BackgroundColor3 = BASE.panel,
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Active = false,
    Visible = false,
    ZIndex = 40,
}, ROOT)
corner(toast, 10)
local toastEdge = outline(toast, 1.4)
toastEdge.Transparency = 1
local toastStroke = accentStroke(toast, DEFAULT_THEME.a, 1, 1)
local toastLabel = inst("TextLabel", {
    BackgroundTransparency = 1,
    Size = UDim2.fromScale(1, 1),
    Font = FONT_MONO,
    TextSize = 12,
    TextColor3 = BASE.text,
    TextTransparency = 1,
    Text = "",
    TextWrapped = true,
}, toast)

local toastToken = 0
local function notify(text, color)
    toastToken += 1
    local t = toastToken
    toastLabel.Text = text
    toastLabel.TextColor3 = color or BASE.text
    toastStroke.Color = color or BASE.text
    toast.Visible = true
    tw(toast, 0.15, { BackgroundTransparency = 0.12 })
    tw(toastEdge, 0.15, { Transparency = 0 })
    tw(toastStroke, 0.15, { Transparency = 0 })
    tw(toastLabel, 0.15, { TextTransparency = 0 })
    task.delay(1.8, function()
        if toastToken ~= t or not toast.Parent then return end
        tw(toast, 0.3, { BackgroundTransparency = 1 })
        tw(toastEdge, 0.3, { Transparency = 1 })
        tw(toastStroke, 0.3, { Transparency = 1 })
        tw(toastLabel, 0.3, { TextTransparency = 1 })
        task.delay(0.32, function()
            if toastToken == t and toast.Parent then toast.Visible = false end
        end)
    end)
end

-- ---------------------------------------------------------------- theme persistence
local CONFIG_FILE = "OJBS_UI_" .. tostring(game.PlaceId) .. ".json"

local function writeThemes()
    local ok, err = pcall(function()
        if not writefile then error("no file api") end
        local out = {}
        for k, v in pairs(State.colors) do
            out[k] = { math.round(v.a.R * 255), math.round(v.a.G * 255), math.round(v.a.B * 255) }
        end
        out.settings = {
            bg      = STYLE.bg,
            opacity = STYLE.opacity,
            scan    = STYLE.scan,
            glow    = STYLE.glow,
            round   = STYLE.round,
            outline = STYLE.outline,
            scale   = STYLE.scale,
        }
        writefile(CONFIG_FILE, HttpService:JSONEncode(out))
    end)
    return ok, err
end

local saveToken = 0
local function saveThemes(deferred)
    saveToken += 1
    if not deferred then return writeThemes() end
    local t = saveToken
    task.delay(0.7, function()
        if t == saveToken then writeThemes() end
    end)
    return true
end

-- Shared by loadThemes and OJBS:SetStyle. Fields that are nil are left
-- alone; clamps match the original loader.
local function mergeStyle(s)
    if type(s.bg) == "table" then
        for k, v in pairs(s.bg) do
            if type(v) == "string" then STYLE.bg[k] = v end
        end
    end
    if s.opacity ~= nil then STYLE.opacity = math.clamp(tonumber(s.opacity) or STYLE.opacity, 0, 1) end
    if s.glow    ~= nil then STYLE.glow    = s.glow ~= false end
    if s.scan    ~= nil then STYLE.scan    = s.scan ~= false end
    if s.round   ~= nil then STYLE.round   = math.clamp(tonumber(s.round) or STYLE.round, 0, 14) end
    if s.outline ~= nil then STYLE.outline = math.clamp(tonumber(s.outline) or STYLE.outline, 0.3, 3) end
    if s.scale   ~= nil then STYLE.scale   = math.clamp(tonumber(s.scale) or STYLE.scale, 0.7, 1.6) end
end

local function loadThemes()
    local ok, data = pcall(function()
        if not (isfile and isfile(CONFIG_FILE)) then return nil end
        return HttpService:JSONDecode(readfile(CONFIG_FILE))
    end)
    if not ok or type(data) ~= "table" then return end
    for k, v in pairs(data) do
        if type(v) == "table" and v[1] then
            local c = Color3.fromRGB(v[1], v[2], v[3])
            State.colors[k] = { a = c, b = lighten(c) }
        end
    end
    if type(data.settings) == "table" then mergeStyle(data.settings) end
end
loadThemes()

-- ---------------------------------------------------------------- windows
local WINDOWS = {}
local TAB_CHANGED = {}   -- internal: fn(windowKey, tabIndex) on tab switch

local function windowOpen(win)
    local vp, inset = viewport()
    local winW = win.frame.AbsoluteSize.X > 0 and win.frame.AbsoluteSize.X or WINDOW_W
    local winH = win.frame.AbsoluteSize.Y > 0 and win.frame.AbsoluteSize.Y or WINDOW_H
    local x
    if IS_MOBILE then
        x = clampRange((vp.X - winW * STYLE.scale) * 0.5, inset, vp.X - winW * STYLE.scale - inset)
    else
        x = vp.X - RAIL_OFF - RAIL_W - 16 - winW * STYLE.scale
        if x < 12 then x = 12 end
    end
    local cyRaw = vp.Y * 0.5 + (win.offsetY or 0)
    local cy = clampRange(cyRaw, winH * 0.5 + inset, vp.Y - winH * 0.5 - inset)
    local y = cy - winH * 0.5

    win.frame.Visible = true
    win.frame.Position = UDim2.fromOffset(x + 56, y)
    if win.frame:IsA("CanvasGroup") then win.frame.GroupTransparency = 1 end
    if win.scale then
        win.scale.Scale = STYLE.scale * 0.985
        tw(win.scale, 0.34, { Scale = STYLE.scale }, Enum.EasingStyle.Quint)
    end
    win.tweenIn = tw(win.frame, 0.34, { Position = UDim2.fromOffset(x, y) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    if win.frame:IsA("CanvasGroup") then tw(win.frame, 0.26, { GroupTransparency = 0 }) end
end

local function windowClose(win)
    if not win.frame.Visible then return end
    if win.tweenIn then win.tweenIn:Cancel(); win.tweenIn = nil end
    local p = win.frame.Position
    tw(win.frame, 0.18, { Position = UDim2.new(p.X.Scale, p.X.Offset + 24, p.Y.Scale, p.Y.Offset) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    if win.frame:IsA("CanvasGroup") then
        local t = tw(win.frame, 0.16, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        t.Completed:Connect(function()
            if State.open ~= win.key then win.frame.Visible = false end
        end)
    else
        win.frame.Visible = false
    end
end

local function closeActive()
    if State.open and WINDOWS[State.open] then windowClose(WINDOWS[State.open]) end
    State.open = nil
    if refreshToggleTab then refreshToggleTab() end
end

local function openWindow(key)
    local win = WINDOWS[key]
    if not win then return end
    if State.open == key then return end
    if State.open and WINDOWS[State.open] then windowClose(WINDOWS[State.open]) end
    State.open = key
    if refreshToggleTab then refreshToggleTab() end
    windowOpen(win)
end

local function makeWindow(key, title, icon, offsetY)
    local win = { key = key, onAccent = {}, pages = {}, offsetY = offsetY or 0 }

    local frame = inst(WIN_CLASS, {
        Position = UDim2.fromOffset(-3000, 0),
        Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
        BackgroundColor3 = BASE.bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Visible = false,
        Active = true,
    }, ROOT)
    corner(frame, 12)
    outline(frame, 2)
    win.frame = frame
    win.scale = inst("UIScale", { Scale = STYLE.scale }, frame)

    local bgLayer = inst("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Active = false,
    }, frame)
    win.bgLayer = bgLayer

    local topHalo = inst("Frame", {
        Position = UDim2.fromOffset(0, -4),
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundColor3 = State.colors[key].a,
        BackgroundTransparency = 0.72,
        BorderSizePixel = 0,
    }, frame)
    local topBar = inst("Frame", { Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, frame)
    local topGrad = gradient(topBar, State.colors[key].a, State.colors[key].b, 0)

    local headerH = IS_MOBILE and 52 or 46
    local header = inst("Frame", { Size = UDim2.fromOffset(WINDOW_W, headerH), BackgroundTransparency = 1 }, frame)
    local dragArea = inst("Frame", { Size = UDim2.new(1, -56, 1, 0), BackgroundTransparency = 1, Active = true }, header)
    local iconLbl = inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(16, 0),
        Size = UDim2.fromOffset(28, headerH),
        Font = FONT_MONO,
        TextSize = 19,
        TextColor3 = State.colors[key].a,
        Text = icon,
    }, header)
    inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(46, 0),
        Size = UDim2.new(1, -120, 1, 0),
        Font = FONT_TITLE,
        TextSize = 17,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
    }, header)

    local closeSize = IS_MOBILE and 36 or 28
    local closeBtn = inst("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0, headerH / 2),
        Size = UDim2.fromOffset(closeSize, closeSize),
        BackgroundColor3 = BASE.panel,
        Text = "✕",
        Font = FONT_MONO,
        TextSize = IS_MOBILE and 16 or 13,
        TextColor3 = BASE.dim,
        AutoButtonColor = false,
    }, header)
    corner(closeBtn, 8)
    outline(closeBtn, 1.2)
    closeBtn.MouseButton1Click:Connect(function() closeActive() end)
    closeBtn.MouseEnter:Connect(function() closeBtn.TextColor3 = RED end)
    closeBtn.MouseLeave:Connect(function() closeBtn.TextColor3 = BASE.dim end)

    local tabBar = inst("ScrollingFrame", {
        Position = UDim2.fromOffset(14, headerH + 4),
        Size = UDim2.new(1, -28, 0, IS_MOBILE and 36 or 30),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollingDirection = Enum.ScrollingDirection.X,
        ClipsDescendants = true,
    }, frame)
    inst("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Center,
    }, tabBar)

    local function tabMaxScroll()
        local viewW = tabBar.AbsoluteSize.X
        local canvasW = tabBar.AbsoluteCanvasSize.X
        if canvasW <= 0 then canvasW = tabBar.CanvasSize.X.Offset end
        return math.max(canvasW - viewW, 0)
    end

    -- Mouse wheel scrolls the tab strip on desktop; touch uses native scroll.
    if not IS_MOBILE then
        track(UIS.InputChanged:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
            if not frame.Visible then return end
            local maxX = tabMaxScroll()
            if maxX <= 0 then return end
            local ap, as = tabBar.AbsolutePosition, tabBar.AbsoluteSize
            local m = UIS:GetMouseLocation()
            if m.X < ap.X or m.X > ap.X + as.X or m.Y < ap.Y - 2 or m.Y > ap.Y + as.Y + 2 then return end
            local x = math.clamp(tabBar.CanvasPosition.X - input.Position.Z * 52, 0, maxX)
            tabBar.CanvasPosition = Vector2.new(x, 0)
        end))
    end

    local bodyTop = headerH + (IS_MOBILE and 44 or 38)
    local bodyBottom = IS_MOBILE and 74 or 30
    local body = inst("Frame", {
        Position = UDim2.fromOffset(0, bodyTop),
        Size = UDim2.new(1, 0, 1, -(bodyTop + bodyBottom)),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
    }, frame)

    local footer = inst("Frame", { Position = UDim2.new(0, 0, 1, -bodyBottom), Size = UDim2.new(1, 0, 0, bodyBottom), BackgroundTransparency = 1 }, frame)
    win.footer = footer
    local statusDot = inst("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 16, 0.5, 0),
        Size = UDim2.fromOffset(6, 6),
        BackgroundColor3 = State.colors[key].a,
        BorderSizePixel = 0,
    }, footer)
    corner(statusDot, 3)
    local statusLbl = inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(28, 0),
        Size = UDim2.new(1, -104, 1, 0),
        Font = FONT_MONO,
        TextSize = 11,
        TextColor3 = BASE.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "ready",
    }, footer)

    function win:status(text)
        statusLbl.Text = text
        statusLbl.TextColor3 = BASE.text
        task.delay(2.4, function()
            if statusLbl.Parent and statusLbl.Text == text then statusLbl.TextColor3 = BASE.dim end
        end)
    end

    function win:addTab(name)
        local idx = #self.pages + 1
        local btn = inst("TextButton", {
            Size = UDim2.fromOffset(TAB_W, IS_MOBILE and 32 or 30),
            BackgroundTransparency = 1,
            Text = name,
            Font = FONT_MONO,
            TextSize = 12,
            TextColor3 = BASE.dim,
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextXAlignment = Enum.TextXAlignment.Center,
            AutoButtonColor = false,
            LayoutOrder = idx,
        }, tabBar)
        local underline = inst("Frame", {
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.new(0, 0, 1, 0),
            Size = UDim2.new(1, 0, 0, 2),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            Visible = false,
        }, btn)
        local ug = gradient(underline, State.colors[self.key].a, State.colors[self.key].b, 0)

        local holder = inst(WIN_CLASS, {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            Visible = false,
        }, body)

        local page = inst("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = IS_MOBILE and 5 or 3,
            ScrollBarImageColor3 = BASE.line,
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            ScrollingDirection = Enum.ScrollingDirection.Y,
            Visible = true,
        }, holder)
        pad(page, 12, 4, 12, 12)
        inst("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, page)

        self.pages[idx] = { btn = btn, page = page, holder = holder, underline = underline, ugrad = ug }
        btn.MouseButton1Click:Connect(function() self:selectTab(idx) end)
        btn.MouseEnter:Connect(function()
            if self.activeTab ~= idx then tw(btn, 0.12, { TextColor3 = BASE.text }) end
        end)
        btn.MouseLeave:Connect(function()
            if self.activeTab ~= idx then tw(btn, 0.14, { TextColor3 = BASE.dim }) end
        end)
        if idx == 1 then self:selectTab(1) end
        return page
    end

    function win:selectTab(idx)
        if self.activeTab == idx then return end
        if not self.pages[idx] then return end
        self.activeTab = idx
        for _, f in ipairs(TAB_CHANGED) do pcall(f, self.key, idx) end
        for i, t in ipairs(self.pages) do
            local on = (i == idx)
            t.btn.TextColor3 = on and State.colors[self.key].a or BASE.dim
            t.underline.Visible = on
            if on then
                t.holder.Visible = true
                t.page.Visible = true
                if t.holder:IsA("CanvasGroup") then
                    t.holder.GroupTransparency = 1
                    tw(t.holder, 0.16, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)
                end
                t.holder.Position = UDim2.fromOffset(0, 6)
                tw(t.holder, 0.24, { Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Quint)
            elseif t.holder.Visible then
                if t.holder:IsA("CanvasGroup") then
                    local h = t.holder
                    local tr = tw(h, 0.1, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
                    tr.Completed:Connect(function()
                        if self.activeTab ~= i then
                            h.Visible = false
                            t.page.Visible = false
                        end
                    end)
                else
                    t.holder.Visible = false
                    t.page.Visible = false
                end
            end
        end
        -- Keep the selected tab scrolled into view.
        task.defer(function()
            local t = self.pages[idx]
            if not t or not t.btn.Parent then return end
            local maxX = tabMaxScroll()
            if maxX <= 0 then return end
            local viewW = tabBar.AbsoluteSize.X
            local cur = tabBar.CanvasPosition.X
            local x = t.btn.AbsolutePosition.X - tabBar.AbsolutePosition.X + cur
            local w = t.btn.AbsoluteSize.X
            local dest = cur
            if x - 8 < cur then
                dest = x - 8
            elseif x + w + 8 > cur + viewW then
                dest = x + w + 8 - viewW
            end
            dest = math.clamp(dest, 0, maxX)
            if math.abs(dest - cur) > 0.5 then
                tw(tabBar, 0.2, { CanvasPosition = Vector2.new(dest, 0) }, Enum.EasingStyle.Quint)
            end
        end)
    end

    function win:refreshAccent()
        local a = State.colors[self.key].a
        local b = State.colors[self.key].b
        for _, fn in ipairs(self.onAccent) do pcall(fn, a) end
        topGrad.Color = ColorSequence.new(a, b)
        topHalo.BackgroundColor3 = a
        iconLbl.TextColor3 = a
        statusDot.BackgroundColor3 = a
        for _, t in ipairs(self.pages) do
            t.ugrad.Color = ColorSequence.new(a, b)
        end
    end

    -- Header drag. Touch ignores movement under TAP_SLOP px so taps don't nudge.
    local dragging, dragTouch = false, false
    local dragStartMouse, dragStartPos = Vector2.new(), Vector2.new()
    local TAP_SLOP = IS_MOBILE and 6 or 0
    dragArea.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if win.tweenIn then pcall(function() win.tweenIn:Cancel() end); win.tweenIn = nil end
        dragging = true
        dragTouch = (input.UserInputType == Enum.UserInputType.Touch)
        dragStartMouse = dragTouch and Vector2.new(input.Position.X, input.Position.Y) or UIS:GetMouseLocation()
        dragStartPos = Vector2.new(frame.AbsolutePosition.X, frame.AbsolutePosition.Y)
    end)
    track(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local m = (dragTouch and input.UserInputType == Enum.UserInputType.Touch)
            and Vector2.new(input.Position.X, input.Position.Y)
            or UIS:GetMouseLocation()
        local sc = win.scale and win.scale.Scale or 1
        local dx = (m.X - dragStartMouse.X) / sc
        local dy = (m.Y - dragStartMouse.Y) / sc
        if TAP_SLOP > 0 and math.abs(dx) + math.abs(dy) < TAP_SLOP then return end
        local vp, inset = viewport()
        local winW = frame.AbsoluteSize.X > 0 and frame.AbsoluteSize.X or WINDOW_W
        frame.Position = UDim2.fromOffset(
            clampRange(dragStartPos.X + dx, -winW + 120, vp.X - 120),
            clampRange(dragStartPos.Y + dy, -6 + inset, vp.Y - 50 - inset)
        )
    end))
    track(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    local scanLayer = inst("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Active = false,
    }, frame)
    win.scanLayer = scanLayer

    pcall(applyBackground, win, STYLE.bg[key] or "classic")
    pcall(applyScan, win, STYLE.scan)

    WINDOWS[key] = win
    return win
end

-- ---------------------------------------------------------------- widgets
-- Every stateful widget returns a plain table handle:
--   { get, set (fires callback), setSilent, instance }
-- Nothing is ever assigned onto a Roblox Instance.
local W = {}
local RGB = {}

function W.section(win, page, text)
    local f = inst("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = nextOrder(page) }, page)
    local l = inst("TextLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Font = FONT_MONO,
        TextSize = 11,
        TextColor3 = State.colors[win.key].a,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = string.upper(text),
    }, f)
    table.insert(win.onAccent, function(a) l.TextColor3 = a end)
    return f
end

function W.note(win, page, text)
    local row = inst("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = BASE.panel,
        BackgroundTransparency = 0.5,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(page),
    }, page)
    corner(row, 8)
    outline(row, 1.1)
    pad(row, 12, 10, 12, 10)
    inst("TextLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = FONT_MONO,
        TextSize = IS_MOBILE and 11 or 12,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        LineHeight = 1.22,
        Text = text,
    }, row)
    return row
end

function W.toggle(win, page, opts)
    local row = inst("Frame", {
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundColor3 = BASE.panel,
        BackgroundTransparency = 0.25,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(page),
    }, page)
    corner(row, 8)
    outline(row, 1.2)
    inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -90, 1, 0),
        Font = FONT_MONO,
        TextSize = 13,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.text,
    }, row)

    local pillW = IS_MOBILE and 46 or 38
    local pillH = IS_MOBILE and 24 or 20
    local knobS = IS_MOBILE and 20 or 16
    local pillHalo = halo(row, State.colors[win.key].a, 12, 0.9)
    pillHalo.Position = UDim2.new(1, -(pillW / 2 + 12), 0.5, 0)
    pillHalo.Size = UDim2.fromOffset(pillW + 14, pillH + 14)

    local pill = inst("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(pillW, pillH),
        BackgroundColor3 = BASE.line,
        BorderSizePixel = 0,
    }, row)
    corner(pill, pillH / 2)
    outline(pill, 1.2)
    local pillGrad = gradient(pill, State.colors[win.key].a, State.colors[win.key].b, 90)

    local knob = inst("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 2, 0.5, 0),
        Size = UDim2.fromOffset(knobS, knobS),
        BackgroundColor3 = Color3.fromRGB(238, 241, 247),
        BorderSizePixel = 0,
    }, pill)
    corner(knob, knobS / 2)
    outline(knob, 1)

    local value = opts.value and true or false
    local function render(animate)
        pill.BackgroundTransparency = value and 0 or 0.75
        pill.BackgroundColor3 = value and Color3.new(1, 1, 1) or BASE.line
        pillGrad.Enabled = value
        pillHalo.Visible = value and STYLE.glow
        local onX = pillW - knobS - 2
        local pos = value and UDim2.new(0, onX, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
        if animate then
            tw(knob, 0.16, { Position = pos }, Enum.EasingStyle.Quint)
        else
            knob.Position = pos
        end
    end
    render(false)
    table.insert(win.onAccent, function()
        pillGrad.Color = ColorSequence.new(State.colors[win.key].a, State.colors[win.key].b)
        pillHalo.BackgroundColor3 = State.colors[win.key].a
    end)

    local function fire() safeCall("toggle", opts.callback, value) end

    local hit = inst("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1) }, row)
    hit.MouseButton1Click:Connect(function()
        value = not value
        render(true)
        fire()
    end)
    return {
        instance  = row,
        get       = function() return value end,
        set       = function(v) value = v and true or false; render(true); fire() end,
        setSilent = function(v) value = v and true or false; render(true) end,
    }
end

function W.slider(win, page, opts)
    local rowH = IS_MOBILE and 58 or 50
    local row = inst("Frame", {
        Size = UDim2.new(1, 0, 0, rowH),
        BackgroundColor3 = BASE.panel,
        BackgroundTransparency = 0.25,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(page),
    }, page)
    corner(row, 8)
    outline(row, 1.2)
    inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 6),
        Size = UDim2.new(1, -100, 0, 16),
        Font = FONT_MONO,
        TextSize = 13,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.text,
    }, row)
    local valLbl = inst("TextLabel", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 6),
        Size = UDim2.fromOffset(90, 16),
        Font = FONT_MONO,
        TextSize = 12,
        TextColor3 = State.colors[win.key].a,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = "",
    }, row)

    local trackHalo = halo(row, State.colors[win.key].a, 6, 0.9)
    trackHalo.Position = UDim2.new(0.5, 0, 0, IS_MOBILE and 44 or 36)
    trackHalo.Size = UDim2.new(1, -16, 0, 14)

    local barY = IS_MOBILE and 40 or 34
    local barH = IS_MOBILE and 6 or 4
    local bar = inst("Frame", {
        Position = UDim2.fromOffset(12, barY),
        Size = UDim2.new(1, -24, 0, barH),
        BackgroundColor3 = BASE.line,
        BorderSizePixel = 0,
    }, row)
    corner(bar, barH / 2)

    local fill = inst("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, bar)
    corner(fill, barH / 2)
    local fillGrad = gradient(fill, State.colors[win.key].a, State.colors[win.key].b, 0)

    local knobS = IS_MOBILE and 18 or 12
    local knob = inst("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(knobS, knobS),
        BackgroundColor3 = Color3.fromRGB(240, 243, 248),
        BorderSizePixel = 0,
    }, bar)
    corner(knob, knobS / 2)
    outline(knob, 1)

    local min, max = opts.min, opts.max
    local step = opts.step or 1
    local value = opts.value or min

    local function quant(raw)
        if step <= 0 then return raw end
        return min + math.floor((raw - min) / step + 0.5) * step
    end
    local function fmt(v)
        if step < 1 then return string.format("%.2f", v) end
        return tostring(math.floor(v + 0.5))
    end
    local function apply(v, fire)
        value = math.clamp(quant(v), min, max)
        local pct = (value - min) / math.max(max - min, 0.0001)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        knob.Position = UDim2.new(pct, 0, 0.5, 0)
        valLbl.Text = fmt(value) .. (opts.suffix or "")
        if fire and opts.callback then opts.callback(value) end
    end

    table.insert(win.onAccent, function()
        valLbl.TextColor3 = State.colors[win.key].a
        trackHalo.BackgroundColor3 = State.colors[win.key].a
        fillGrad.Color = ColorSequence.new(State.colors[win.key].a, State.colors[win.key].b)
    end)

    local hitH = IS_MOBILE and 32 or 24
    local hit = inst("TextButton", {
        BackgroundTransparency = 1,
        Text = "",
        Position = UDim2.fromOffset(0, barY - (hitH - barH) * 0.5),
        Size = UDim2.new(1, 0, 0, hitH),
    }, row)

    local function updateForX(px)
        if not (bar and bar.Parent) then return end
        local w = math.max(bar.AbsoluteSize.X, 1)
        local pct = math.clamp((px - bar.AbsolutePosition.X) / w, 0, 1)
        apply(min + pct * (max - min), true)
    end

    local activeDrag = nil
    hit.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        tw(knob, 0.1, { Size = UDim2.fromOffset(knobS + 4, knobS + 4) }, Enum.EasingStyle.Quint)
        updateForX(input.Position.X)
        activeDrag = {
            pointer = input,
            isTouch = (input.UserInputType == Enum.UserInputType.Touch),
        }
    end)
    track(UIS.InputChanged:Connect(function(input)
        if not activeDrag then return end
        if activeDrag.isTouch then
            if input == activeDrag.pointer then
                updateForX(input.Position.X)
            end
        else
            if input.UserInputType == Enum.UserInputType.MouseMovement then
                updateForX(UIS:GetMouseLocation().X)
            end
        end
    end))
    track(UIS.InputEnded:Connect(function(input)
        if not activeDrag then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if activeDrag.isTouch and input ~= activeDrag.pointer then return end
            activeDrag = nil
            if knob.Parent then tw(knob, 0.14, { Size = UDim2.fromOffset(knobS, knobS) }, Enum.EasingStyle.Quint) end
        end
    end))

    apply(value, false)
    return {
        instance  = row,
        get       = function() return value end,
        set       = function(v) apply(v, true) end,
        setSilent = function(v) apply(v, false) end,
    }
end

function W.input(win, page, opts)
    local rowH = IS_MOBILE and 48 or 40
    local row = inst("Frame", {
        Size = UDim2.new(1, 0, 0, rowH),
        BackgroundColor3 = BASE.panel,
        BackgroundTransparency = 0.25,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(page),
    }, page)
    corner(row, 8)
    outline(row, 1.2)
    inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.44, -12, 1, 0),
        Font = FONT_MONO,
        TextSize = 13,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.text,
    }, row)
    local tb = inst("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.new(0.56, -22, 0, IS_MOBILE and 32 or 26),
        BackgroundColor3 = BASE.bg2,
        BorderSizePixel = 0,
        Font = FONT_MONO,
        TextSize = IS_MOBILE and 13 or 12,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.value or "",
        PlaceholderText = opts.placeholder or "",
        PlaceholderColor3 = BASE.dim,
        ClearTextOnFocus = false,
    }, row)
    corner(tb, 6)
    outline(tb, 1.2)
    pad(tb, 8, 0, 8, 0)
    local s = accentStroke(tb, BASE.line, 1, 0.5)

    local function fire() safeCall("input callback", opts.callback, tb.Text) end

    tb.Focused:Connect(function()
        s.Color = State.colors[win.key].a
        s.Transparency = 0.2
    end)
    tb.FocusLost:Connect(function()
        s.Color = BASE.line
        s.Transparency = 0.5
        fire()
    end)
    return {
        instance  = tb,
        get       = function() return tb.Text end,
        set       = function(v) tb.Text = tostring(v or ""); fire() end,
        setSilent = function(v) tb.Text = tostring(v or "") end,
    }
end

-- Stateless: returns the TextButton itself.
function W.button(win, page, opts)
    local rowH = IS_MOBILE and 42 or 34
    local row = inst("Frame", {
        Size = UDim2.new(1, 0, 0, rowH),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(page),
    }, page)
    local glow = halo(row, State.colors[win.key].a, 11, 0.92)
    glow.Size = UDim2.new(1, 10, 0, rowH + 8)

    local b = inst("TextButton", {
        Size = UDim2.new(1, 0, 0, rowH),
        BackgroundColor3 = BASE.panel,
        BorderSizePixel = 0,
        Font = FONT_MONO,
        TextSize = 13,
        TextColor3 = State.colors[win.key].a,
        Text = opts.text,
        AutoButtonColor = false,
    }, row)
    corner(b, 8)
    outline(b, 1.4)
    local edge = accentStroke(b, State.colors[win.key].a, 1, 0.55)
    local edge2
    if opts.extraOutline then
        edge2 = accentStroke(b, State.colors[win.key].a, 4, 0.3)
    end

    b.MouseEnter:Connect(function()
        tw(b, 0.14, { BackgroundColor3 = BASE.panel2 }, Enum.EasingStyle.Quint)
        tw(edge, 0.14, { Transparency = 0.15 })
        if edge2 then tw(edge2, 0.14, { Transparency = 0.05 }) end
        tw(glow, 0.14, { BackgroundTransparency = 0.72 })
    end)
    b.MouseLeave:Connect(function()
        tw(b, 0.16, { BackgroundColor3 = BASE.panel }, Enum.EasingStyle.Quint)
        tw(edge, 0.16, { Transparency = 0.55 })
        if edge2 then tw(edge2, 0.16, { Transparency = 0.3 }) end
        tw(glow, 0.16, { BackgroundTransparency = 0.92 })
    end)
    table.insert(win.onAccent, function()
        b.TextColor3 = State.colors[win.key].a
        edge.Color = State.colors[win.key].a
        if edge2 then edge2.Color = State.colors[win.key].a end
        glow.BackgroundColor3 = State.colors[win.key].a
    end)
    if opts.callback then
        b.MouseButton1Click:Connect(function() safeCall("button", opts.callback) end)
    end
    return b
end

function W.cycle(win, page, opts)
    local i = 1
    for idx, v in ipairs(opts.options) do
        if v == opts.value then i = idx end
    end
    local b = W.button(win, page, { text = opts.text .. ": " .. tostring(opts.options[i]) })

    local function choose(v)
        for idx, opt in ipairs(opts.options) do
            if opt == v then
                i = idx
                b.Text = opts.text .. ": " .. tostring(v)
                return true
            end
        end
        return false
    end

    local api = { instance = b }
    api.get = function() return opts.options[i] end
    api.set = function(v)
        if choose(v) then safeCall("cycle set", opts.callback, v) end
    end
    api.setSilent = function(v) choose(v) end

    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(function()
            i = i % #opts.options + 1
            local v = opts.options[i]
            b.Text = opts.text .. ": " .. tostring(v)
            if opts.callback then opts.callback(v) end
        end)
        if not ok then warn("[OJBS] cycle error:", err) end
    end)
    return api
end

function W.colorPicker(win, page)
    local row = inst("Frame", {
        Size = UDim2.new(1, 0, 0, IS_MOBILE and 50 or 40),
        BackgroundColor3 = BASE.panel,
        BackgroundTransparency = 0.25,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(page),
    }, page)
    corner(row, 8)
    outline(row, 1.2)
    inst("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.4, -12, 1, 0),
        Font = FONT_MONO,
        TextSize = 13,
        TextColor3 = BASE.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Accent",
    }, row)

    local sw = IS_MOBILE and 22 or 18
    local sp = 6
    local holder = inst("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(#SWATCHES * (sw + sp) - sp, sw),
        BackgroundTransparency = 1,
    }, row)
    for i, c in ipairs(SWATCHES) do
        local s = inst("TextButton", {
            Position = UDim2.fromOffset((i - 1) * (sw + sp), 0),
            Size = UDim2.fromOffset(sw, sw),
            BackgroundColor3 = c,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
        }, holder)
        corner(s, 5)
        outline(s, 1.2)
        s.MouseButton1Click:Connect(function() safeCall("swatch", setAccent, win, c) end)
    end

    local rs = W.slider(win, page, { text = "Red",   min = 0, max = 255, step = 1, value = math.round(State.colors[win.key].a.R * 255),
        callback = function(v) pushRGB(win, v, nil, nil) end })
    local gs = W.slider(win, page, { text = "Green", min = 0, max = 255, step = 1, value = math.round(State.colors[win.key].a.G * 255),
        callback = function(v) pushRGB(win, nil, v, nil) end })
    local bs = W.slider(win, page, { text = "Blue",  min = 0, max = 255, step = 1, value = math.round(State.colors[win.key].a.B * 255),
        callback = function(v) pushRGB(win, nil, nil, v) end })
    RGB[win.key] = { rs = rs, gs = gs, bs = bs }
    return row
end

setAccent = function(win, color)
    State.colors[win.key].a = color
    State.colors[win.key].b = lighten(color)
    win:refreshAccent()
    local ref = RGB[win.key]
    if ref then
        ref.rs.setSilent(math.round(color.R * 255))
        ref.gs.setSilent(math.round(color.G * 255))
        ref.bs.setSilent(math.round(color.B * 255))
    end
    if refreshRailColors then refreshRailColors() end
    saveThemes(true)
end

pushRGB = function(win, r, g, b)
    local c = State.colors[win.key].a
    setAccent(win, Color3.new(
        r and r / 255 or c.R,
        g and g / 255 or c.G,
        b and b / 255 or c.B
    ))
end

function W.themeSaver(win, page)
    W.section(win, page, "Saving")
    W.button(win, page, {
        text = "Save theme",
        callback = function()
            local ok, err = saveThemes(false)
            if ok then
                notify("theme saved", State.colors[win.key].a)
                win:status("theme saved to " .. CONFIG_FILE)
            else
                notify("save failed: " .. tostring(err), RED)
            end
        end,
    })
    W.button(win, page, {
        text = "Reset to default",
        callback = function()
            setAccent(win, THEMES[win.key].a)
            saveThemes(false)
            notify("theme reset", THEMES[win.key].a)
        end,
    })
end

-- Virtualised list: a fixed pool of row buttons re-bound on scroll.
function W.list(win, page, opts)
    local _ = win
    local H = opts.height or 190
    local rowH = opts.rowH or (IS_MOBILE and 36 or 30)
    local poolSize = opts.pool or 14

    local frame = inst("Frame", {
        Size = UDim2.new(1, 0, 0, H),
        BackgroundColor3 = BASE.bg2,
        BackgroundTransparency = 0.2,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        LayoutOrder = nextOrder(page),
    }, page)
    corner(frame, 8)
    outline(frame, 1.4)

    local sf = inst("ScrollingFrame", {
        Size = UDim2.new(1, -6, 1, -6),
        Position = UDim2.fromOffset(3, 3),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = IS_MOBILE and 5 or 3,
        ScrollBarImageColor3 = BASE.line,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, frame)

    local items, rows, bound = {}, {}, {}

    local function render()
        local top = sf.CanvasPosition.Y
        -- First row whose box (idx-1)*rowH .. idx*rowH overlaps the viewport.
        local first = math.max(1, math.floor(top / rowH) + 1)
        for i = 1, poolSize do
            local idx = first + i - 1
            local item = items[idx]
            local row = rows[i]
            bound[i] = item
            if item then
                row.Visible = true
                row.Position = UDim2.fromOffset(0, (idx - 1) * rowH)
                row.Text = opts.text(item)
                row.TextColor3 = BASE.text
                if opts.paint then opts.paint(item, row) end
            else
                row.Visible = false
            end
        end
    end

    for i = 1, poolSize do
        local row = inst("TextButton", {
            Size = UDim2.new(1, -6, 0, rowH - 2),
            BackgroundColor3 = BASE.panel,
            BackgroundTransparency = 0.35,
            BorderSizePixel = 0,
            Font = FONT_MONO,
            TextSize = 12,
            TextColor3 = BASE.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = "",
            AutoButtonColor = false,
            Visible = false,
        }, sf)
        corner(row, 6)
        outline(row, 1)
        pad(row, 8, 0, 8, 0)
        rows[i] = row
        row.MouseEnter:Connect(function()
            if bound[i] then
                tw(row, 0.12, { BackgroundColor3 = BASE.panel2, BackgroundTransparency = 0.1 }, Enum.EasingStyle.Quint)
            end
        end)
        row.MouseLeave:Connect(function()
            if bound[i] then
                tw(row, 0.16, { BackgroundColor3 = BASE.panel, BackgroundTransparency = 0.35 }, Enum.EasingStyle.Quint)
                if opts.paint then opts.paint(bound[i], row) end
            end
        end)
        row.MouseButton1Click:Connect(function()
            local item = bound[i]
            if item then safeCall("list row", opts.onRow, item) end
        end)
    end

    local api = { instance = frame, scroller = sf }
    function api.set(list)
        items = list or {}
        sf.CanvasSize = UDim2.new(0, 0, 0, math.max(#items * rowH, 1))
        if sf.CanvasPosition.Y ~= 0 then sf.CanvasPosition = Vector2.new(0, 0) end
        render()
    end
    function api.refresh() render() end

    track(sf:GetPropertyChangedSignal("CanvasPosition"):Connect(render))
    track(sf:GetPropertyChangedSignal("AbsoluteSize"):Connect(render))
    return api
end

-- ---------------------------------------------------------------- style tab
do
    local function applyRounds()
        for _, e in ipairs(CORNERS) do
            if e.ui.Parent then e.ui.CornerRadius = UDim.new(0, math.min(e.r, STYLE.round)) end
        end
    end
    local function applyOutlines()
        for _, e in ipairs(OUTLINES) do
            if e.s.Parent then e.s.Thickness = math.max(e.base * STYLE.outline, 0.2) end
        end
    end
    local function applyGlows()
        for _, h in ipairs(HALOS) do
            if h.Parent then h.Visible = STYLE.glow end
        end
    end
    local function applyScales()
        for _, w in pairs(WINDOWS) do
            if w.scale then w.scale.Scale = STYLE.scale end
        end
    end
    local function applyScans()
        for _, w in pairs(WINDOWS) do applyScan(w, STYLE.scan) end
    end
    local function applyBgs()
        for k, w in pairs(WINDOWS) do applyBackground(w, STYLE.bg[k] or "classic") end
    end

    applyAllStyles = function()
        applyRounds(); applyOutlines(); applyGlows(); applyScales(); applyScans(); applyBgs()
    end

    local function cornerLabel()
        return (STYLE.round <= 1) and "Sharp" or ((STYLE.round >= 10) and "Soft" or "Boxed")
    end

    -- Every style-tab control in every window, paired with a reader that
    -- returns its value from STYLE. syncStyleControls() pushes STYLE back
    -- into them with setSilent, so it never fires callbacks or saves.
    local STYLE_CONTROLS = {}
    local function bind(handle, read)
        STYLE_CONTROLS[#STYLE_CONTROLS + 1] = { h = handle, read = read }
        return handle
    end
    syncStyleControls = function()
        for _, c in ipairs(STYLE_CONTROLS) do
            if c.h.instance and c.h.instance.Parent then
                pcall(c.h.setSilent, c.read())
            end
        end
    end

    function W.styleTab(win, page)
        W.section(win, page, "Background")
        bind(W.cycle(win, page, {
            text = "Pattern",
            options = BG_KINDS,
            value = STYLE.bg[win.key] or "classic",
            callback = function(v)
                STYLE.bg[win.key] = v
                applyBackground(win, v)
                syncStyleControls()
                saveThemes(true)
            end,
        }), function() return STYLE.bg[win.key] or "classic" end)
        local bgToken = 0
        bind(W.slider(win, page, {
            text = "Pattern strength", min = 0, max = 1, step = 0.05, value = STYLE.opacity,
            callback = function(v)
                STYLE.opacity = v
                bgToken += 1
                local t = bgToken
                task.delay(0.15, function()
                    if t == bgToken then applyBgs() end
                end)
                syncStyleControls()
                saveThemes(true)
            end,
        }), function() return STYLE.opacity end)
        bind(W.toggle(win, page, {
            text = "Scanlines", value = STYLE.scan,
            callback = function(v) STYLE.scan = v; applyScans(); syncStyleControls(); saveThemes(true) end,
        }), function() return STYLE.scan end)

        W.section(win, page, "Shape")
        bind(W.cycle(win, page, {
            text = "Corners",
            options = { "Sharp", "Boxed", "Soft" },
            value = cornerLabel(),
            callback = function(v)
                STYLE.round = (v == "Sharp") and 0 or ((v == "Soft") and 14 or 4)
                applyRounds(); syncStyleControls(); saveThemes(true)
            end,
        }), cornerLabel)
        bind(W.slider(win, page, {
            text = "Outline weight", min = 0.4, max = 2.5, step = 0.05, value = STYLE.outline,
            callback = function(v) STYLE.outline = v; applyOutlines(); syncStyleControls(); saveThemes(true) end,
        }), function() return STYLE.outline end)
        bind(W.toggle(win, page, {
            text = "Button glow", value = STYLE.glow,
            callback = function(v) STYLE.glow = v; applyGlows(); syncStyleControls(); saveThemes(true) end,
        }), function() return STYLE.glow end)
        bind(W.slider(win, page, {
            text = "Window scale", min = 0.8, max = 1.4, step = 0.02, value = STYLE.scale,
            callback = function(v) STYLE.scale = v; applyScales(); syncStyleControls(); saveThemes(true) end,
        }), function() return STYLE.scale end)

        W.section(win, page, "Accent")
        W.button(win, page, {
            text = "Copy accent to all windows",
            callback = function()
                local c = State.colors[win.key].a
                for _, st in pairs(State.colors) do
                    st.a = c
                    st.b = lighten(c)
                end
                for _, w in pairs(WINDOWS) do w:refreshAccent() end
                if refreshRailColors then refreshRailColors() end
                saveThemes(false)
                notify("accent copied to every window", c)
            end,
        })

        W.section(win, page, "Danger")
        W.button(win, page, {
            text = "Wipe saved settings",
            callback = function()
                local ok = pcall(function()
                    if delfile and isfile and isfile(CONFIG_FILE) then delfile(CONFIG_FILE) end
                end)
                notify(ok and "saved settings wiped" or "file api blocked", RED)
            end,
        })
        W.button(win, page, {
            text = "UNLOAD UI  ·  full teardown",
            callback = function() if doUnload then doUnload() end end,
        })
    end
end

-- ---------------------------------------------------------------- rail
local railButtons = {}
local railOrder = {}

local function makeRailButton(key, symbol)
    if railButtons[key] then return end
    local offsetY = 16 + #railOrder * (RAIL_W + 12)
    local shownX, hiddenX
    if IS_MOBILE then
        shownX = -RAIL_OFF
        hiddenX = -RAIL_OFF - RAIL_W - 12
    else
        shownX = -RAIL_OFF
        hiddenX = 96
    end
    local shownC = shownX - RAIL_W * 0.5
    local hiddenC = hiddenX - RAIL_W * 0.5

    local theme = State.colors[key] or DEFAULT_THEME

    local glow = inst("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(1, hiddenC, 0, offsetY),
        Size = UDim2.fromOffset(RAIL_W + 18, RAIL_W + 18),
        BackgroundColor3 = theme.a,
        BackgroundTransparency = 0.88,
        BorderSizePixel = 0,
        Active = false,
        Visible = STYLE.glow,
    }, ROOT)
    corner(glow, 20)
    HALOS[#HALOS + 1] = glow

    local b = inst("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, hiddenX, 0, offsetY),
        Size = UDim2.fromOffset(RAIL_W, RAIL_W),
        BackgroundColor3 = BASE.panel,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
    }, ROOT)
    corner(b, 14)
    outline(b, 1.6)

    local tint = inst("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, b)
    corner(tint, 14)
    local grad = inst("UIGradient", {
        Rotation = 120,
        Color = ColorSequence.new(theme.a, theme.b),
        Transparency = NumberSequence.new(0.6),
    }, tint)

    inst("TextLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Font = FONT_MONO,
        TextSize = IS_MOBILE and 20 or 22,
        TextColor3 = Color3.fromRGB(255, 255, 255),
        Text = symbol,
    }, b)

    local e = {
        btn = b, glow = glow, grad = grad,
        shown = UDim2.new(1, shownX, 0, offsetY),
        hidden = UDim2.new(1, hiddenX, 0, offsetY),
        gshown = UDim2.new(1, shownC, 0, offsetY),
        ghidden = UDim2.new(1, hiddenC, 0, offsetY),
    }
    railButtons[key] = e
    railOrder[#railOrder + 1] = key

    -- Respect current rail state if the button is added after the rail opened.
    b.Position = State.railOpen and e.shown or e.hidden
    glow.Position = State.railOpen and e.gshown or e.ghidden

    b.MouseEnter:Connect(function()
        tw(b, 0.15, { Size = UDim2.fromOffset(RAIL_W + 4, RAIL_W + 4) }, Enum.EasingStyle.Quint)
        tw(grad, 0.15, { Transparency = NumberSequence.new(0.38) })
        tw(glow, 0.15, { BackgroundTransparency = 0.7 })
    end)
    b.MouseLeave:Connect(function()
        tw(b, 0.15, { Size = UDim2.fromOffset(RAIL_W, RAIL_W) }, Enum.EasingStyle.Quint)
        tw(grad, 0.15, { Transparency = NumberSequence.new(0.6) })
        tw(glow, 0.15, { BackgroundTransparency = 0.88 })
    end)
    b.MouseButton1Click:Connect(function()
        safeCall("rail button", function()
            if State.open == key then closeActive() else openWindow(key) end
        end)
    end)
end

-- Draggable toggle tab (top-right). Same action as RightCtrl; this is the
-- only way to reach the rail on touch-only devices.
local toggleTab = inst("TextButton", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -8, 0, 8),
    Size = UDim2.fromOffset(IS_MOBILE and 44 or 36, IS_MOBILE and 44 or 36),
    BackgroundColor3 = BASE.panel,
    BorderSizePixel = 0,
    Text = USE_EMOJI and "⚙" or "≡",
    Font = FONT_MONO,
    TextSize = IS_MOBILE and 20 or 18,
    TextColor3 = DEFAULT_THEME.a,
    AutoButtonColor = false,
    ZIndex = 30,
}, ROOT)
corner(toggleTab, 10)
outline(toggleTab, 1.4)
local toggleTabStroke = accentStroke(toggleTab, DEFAULT_THEME.a, 1, 0.6)

-- The gear takes the open window's accent, else the first window created.
local WINDOW_ORDER = {}
refreshToggleTab = function()
    local key = State.open or WINDOW_ORDER[1]
    local c = (key and State.colors[key] or DEFAULT_THEME).a
    toggleTab.TextColor3 = c
    toggleTabStroke.Color = c
end

-- Declared before the drag block so the click handler can see it.
local function toggleRail()
    if State.railOpen then
        setRail(false)
        closeActive()
    else
        setRail(true)
    end
end

do
    -- 6px slop: a drag past it moves the tab and swallows the click that
    -- follows on release; a shorter press is a normal tap.
    local DRAG_SLOP = 6
    local dragging, moved = false, false
    local dragStart, dragPos
    toggleTab.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        moved = false
        dragStart = UIS:GetMouseLocation()
        dragPos = toggleTab.Position
    end)
    track(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local m = UIS:GetMouseLocation()
        local dx = m.X - dragStart.X
        local dy = m.Y - dragStart.Y
        if not moved and math.abs(dx) + math.abs(dy) >= DRAG_SLOP then moved = true end
        if moved then
            toggleTab.Position = UDim2.new(dragPos.X.Scale, dragPos.X.Offset + dx, dragPos.Y.Scale, dragPos.Y.Offset + dy)
        end
    end))
    track(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    toggleTab.MouseButton1Click:Connect(function()
        if moved then moved = false; return end
        safeCall("toggle tab", toggleRail)
    end)
end

local badgeShow
do
    -- TODO: "(BUILD 1.0)" is app-specific text from the original script.
    -- Kept so the rail-open visual is unchanged; consider making it an option.
    local COL = Color3.fromRGB(90, 170, 255)
    local TXT = "(BUILD 1.0)"

    local lbl = inst("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 8),
        Size = UDim2.fromOffset(IS_MOBILE and 220 or 430, 46),
        BackgroundTransparency = 1,
        Font = FONT_TITLE,
        TextSize = IS_MOBILE and 22 or 34,
        TextColor3 = COL,
        TextTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Top,
        Text = TXT,
        Visible = false,
    }, ROOT)

    badgeShow = function(show)
        if show then
            lbl.Visible = true
            lbl.Position = UDim2.new(1, -18, 0, 2)
            tw(lbl, 0.3, { TextTransparency = 0 })
            tw(lbl, 0.3, { Position = UDim2.new(1, -18, 0, 8) }, Enum.EasingStyle.Quint)
        else
            local t = tw(lbl, 0.2, { TextTransparency = 1 })
            t.Completed:Connect(function()
                if lbl.TextTransparency > 0.9 then lbl.Visible = false end
            end)
        end
    end
end

refreshRailColors = function()
    for key, e in pairs(railButtons) do
        local theme = State.colors[key] or DEFAULT_THEME
        e.grad.Color = ColorSequence.new(theme.a, theme.b)
        e.glow.BackgroundColor3 = theme.a
    end
    refreshToggleTab()
end

setRail = function(open)
    State.railOpen = open
    if badgeShow then badgeShow(open) end
    for i, key in ipairs(railOrder) do
        local e = railButtons[key]
        if e then
            task.delay((i - 1) * 0.05, function()
                if not e.btn.Parent then return end
                tw(e.btn, 0.32, { Position = open and e.shown or e.hidden }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
                tw(e.glow, 0.32, { Position = open and e.gshown or e.ghidden }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
            end)
        end
    end
end

applyAllStyles()

-- ---------------------------------------------------------------- input
track(UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == TOGGLE_KEY then toggleRail() end
end))

-- ---------------------------------------------------------------- teardown
local unloaded = false
local cleanupFn

doUnload = function()
    if unloaded then return end
    unloaded = true

    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    table.clear(CONNS)

    -- The original compared against doUnload, but stored a wrapper, so the
    -- global was never cleared. Compare against the stored function instead.
    if genv.OJBS_Cleanup == cleanupFn then genv.OJBS_Cleanup = nil end
    pcall(function() gui:Destroy() end)
    print("[OJBS] unloaded — gui destroyed")
end

cleanupFn = function() pcall(doUnload) end
genv.OJBS_Cleanup = cleanupFn

-- ================================================================ public API
-- Handles are plain tables built from closures (no metatables).

local OJBS = {}
local HANDLES = {}

local function makePage(win, frame)
    local p = { instance = frame }
    function p:Section(text)     return W.section(win, frame, text) end
    function p:Note(text)        return W.note(win, frame, text) end
    function p:Toggle(opts)      return W.toggle(win, frame, opts or {}) end
    function p:Slider(opts)      return W.slider(win, frame, opts or {}) end
    function p:Input(opts)       return W.input(win, frame, opts or {}) end
    function p:Button(opts)      return W.button(win, frame, opts or {}) end
    function p:Cycle(opts)       return W.cycle(win, frame, opts or {}) end
    function p:List(opts)        return W.list(win, frame, opts or {}) end
    function p:ColorPicker()     return W.colorPicker(win, frame) end
    function p:ThemeSaver()      return W.themeSaver(win, frame) end
    function p:StyleTab()        return W.styleTab(win, frame) end
    return p
end

function OJBS:CreateWindow(cfg)
    cfg = cfg or {}
    local key = tostring(cfg.key or ("window" .. tostring(#railOrder + 1)))
    if HANDLES[key] then return HANDLES[key] end

    -- Default accent for this key ("Reset to default" returns here).
    if typeof(cfg.accent) == "Color3" then
        THEMES[key] = { a = cfg.accent, b = lighten(cfg.accent) }
    else
        THEMES[key] = THEMES[key] or DEFAULT_THEME
    end
    -- A saved colour from the config file wins over the default.
    if not State.colors[key] then
        State.colors[key] = { a = THEMES[key].a, b = THEMES[key].b }
    end

    local icon = cfg.icon or (USE_EMOJI and "⚙" or "≡")
    local win = makeWindow(key, cfg.title or key, icon, tonumber(cfg.offsetY) or 0)
    makeRailButton(key, icon)
    WINDOW_ORDER[#WINDOW_ORDER + 1] = key
    refreshToggleTab()

    local h = { key = key, instance = win.frame }
    function h:AddTab(name)   return makePage(win, win:addTab(tostring(name))) end
    function h:SelectTab(i)   win:selectTab(i) end
    function h:Status(text)   win:status(tostring(text)) end
    function h:OnAccent(fn)   if type(fn) == "function" then table.insert(win.onAccent, fn) end end
    function h:Open()         openWindow(key) end
    function h:Close()        if State.open == key then closeActive() end end

    HANDLES[key] = h
    return h
end

-- Rail buttons are created by CreateWindow. This is exposed for a button
-- whose window is created later; clicking it before then does nothing.
function OJBS:CreateRailButton(key, icon)
    makeRailButton(tostring(key), icon or (USE_EMOJI and "⚙" or "≡"))
end

function OJBS:Notify(text, color)
    notify(tostring(text), color)
end

function OJBS:RailOpen(open)
    if open then
        setRail(true)
    else
        setRail(false)
        closeActive()
    end
end

function OJBS:GetStyle()
    local bg = {}
    for k, v in pairs(STYLE.bg) do bg[k] = v end
    return {
        bg = bg, opacity = STYLE.opacity, scan = STYLE.scan, glow = STYLE.glow,
        round = STYLE.round, outline = STYLE.outline, scale = STYLE.scale,
    }
end

-- Applies to every window and updates any open StyleTab controls.
-- Values are clamped as on load (scale 0.7-1.6); the scale slider only
-- spans 0.8-1.4, so out-of-range values show at the slider's end.
function OJBS:SetStyle(s)
    if type(s) ~= "table" then return end
    mergeStyle(s)
    applyAllStyles()
    syncStyleControls()
    saveThemes(true)
end

function OJBS:Teardown()
    doUnload()
end

return OJBS
