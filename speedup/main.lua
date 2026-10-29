local mod = RegisterMod("Speedup", 1)
local game = Game()
local sfx = SFXManager()
local music = MusicManager()
local json = require("json")

local MIN, MAX, STEP = 100, 300, 5

local function isBoss(room)
    local t = room:GetType()
    return t == RoomType.ROOM_BOSS or t == RoomType.ROOM_MINIBOSS or t == RoomType.ROOM_BOSSRUSH
end

-- Speed settings (percent: 100 = vanilla) are rules: the first whose test matches the current room applies.
local settings = {
    { key = "clear", name = "Cleared room", default = 130, test = function(room) return room:IsClear() end,
      info = "Rooms with no enemies left: exploring, shops, treasure rooms." },
    { key = "boss", name = "Boss fight", default = 120, test = isBoss,
      info = "Boss, miniboss and Boss Rush rooms until cleared." },
    { key = "combat", name = "Combat", default = 120, test = function() return true end,
      info = "Every other room with enemies." },
    { key = "music", name = "Faster music", default = false,
      info = "Music plays faster (and higher pitched) to match game speed." },
    { key = "sfx", name = "Faster sounds", default = false,
      info = "Sound effects play faster (and higher pitched) to match game speed." },
}

local cfg = {}
for _, s in ipairs(settings) do cfg[s.key] = s.default end

if mod:HasData() then
    local ok, d = pcall(json.decode, mod:LoadData())
    if ok and type(d) == "table" then
        for k, v in pairs(cfg) do
            if type(d[k]) == type(v) then cfg[k] = d[k] end
        end
    end
end

local function set(key, v)
    if type(v) == "number" then v = math.max(MIN, math.min(MAX, v)) end
    cfg[key] = v
    if key == "music" and not v then music:ResetPitch() end
    mod:SaveData(json.encode(cfg))
end

local function label(pct)
    return ("x%.2f"):format(pct / 100)
end

local function current()
    local room = game:GetRoom()
    for _, s in ipairs(settings) do
        if s.test and s.test(room) then return s end
    end
end

local acc, inside = 0, false
-- Sound ids with no samples; IsPlaying on them spams "[warn] Sound N has no samples" into log.txt every frame.
local EMPTY_SOUNDS = { [837] = true, [846] = true }
local playing = {}

-- Each real 1/30s frame, run (speed - 1) extra full game ticks, so everything keeps its relative timing.
-- LATE so every other mod finishes its POST_UPDATE for this tick before the next one starts.
-- Don't move this to MC_POST_RENDER to spread ticks over drawn frames: Game:Update there blanks whole frames.
-- ponytail: whole ticks per 1/30s, so x2/x3 move evenly and in-between speeds alternate (x1.5 = 1,2,1,2 ticks)
mod:AddPriorityCallback(ModCallbacks.MC_POST_UPDATE, CallbackPriority.LATE, function()
    if inside then return end -- Game:Update fires POST_UPDATE again
    local pct = cfg[current().key]
    acc = acc + pct - 100
    inside = true
    while acc >= 100 do
        acc = acc - 100
        game:Update()
    end
    inside = false

    -- Isaac can only resample audio, so faster also means higher pitch.
    local pitch = pct / 100
    if cfg.music then music:PitchSlide(pitch) end
    if cfg.sfx then
        -- ponytail: polls every vanilla sound id; modded sounds above NUM_SOUND_EFFECTS are skipped
        for id = 1, SoundEffect.NUM_SOUND_EFFECTS - 1 do
            local on = not EMPTY_SOUNDS[id] and sfx:IsPlaying(id)
            if on and not playing[id] then sfx:AdjustPitch(id, pitch) end
            playing[id] = on
        end
    end
end)

-- UI ------------------------------------------------------------------------

local pixel = Sprite()
pixel:Load("gfx/speedup/pixel.anm2", true)
pixel:Play("Idle", true)

local font = Font()
font:Load("font/pftempestasevencondensed.fnt")
if not font:IsLoaded() then font:Load("font/terminus.fnt") end

local BG = { 0.08, 0.06, 0.05, 0.88 }
local ACCENT = { 0.92, 0.55, 0.22, 1 }
local TRACK = { 0.28, 0.22, 0.19, 1 }
local HILITE = { 1, 1, 1, 0.08 }
local TEXT = KColor(0.95, 0.9, 0.82, 1)
local DIM = KColor(0.6, 0.55, 0.5, 1)
local HOT = KColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)

local function rect(x, y, w, h, c)
    pixel.Scale = Vector(w, h)
    pixel.Color = Color(c[1], c[2], c[3], c[4], 0, 0, 0)
    pixel:Render(Vector(x, y), Vector.Zero, Vector.Zero)
end

local function text(s, x, y, c)
    font:DrawString(s, x, y, c, 0, false)
end

local function textRight(s, right, y, c)
    text(s, right - font:GetStringWidth(s), y, c)
end

local function bar(x, y, w, pct)
    rect(x, y, w, 4, TRACK)
    rect(x, y, w * (pct - MIN) / (MAX - MIN), 4, ACCENT)
end

local open, sel = false, 1
local toast, toastUntil = nil, 0

local function drawPanel()
    local W, ROW = 256, 16
    local H = 34 + #settings * ROW + 22
    local x = math.floor((Isaac.GetScreenWidth() - W) / 2)
    local y = math.floor((Isaac.GetScreenHeight() - H) / 2)
    local now = current()

    rect(x, y, W, H, BG)
    rect(x, y, W, 2, ACCENT)
    text("SPEEDUP", x + 10, y + 8, HOT)
    textRight("now: " .. now.name, x + W - 10, y + 8, DIM)
    rect(x + 10, y + 24, W - 20, 1, TRACK)

    for i, s in ipairs(settings) do
        local ry = y + 30 + (i - 1) * ROW
        if i == sel then
            rect(x + 4, ry - 1, W - 8, ROW, HILITE)
            text(">", x + 8, ry, HOT)
        end
        text(s.name, x + 18, ry, s == now and HOT or TEXT)
        local v = cfg[s.key]
        if type(v) == "number" then
            bar(x + 110, ry + 5, 80, v)
            textRight(label(v), x + W - 10, ry, TEXT)
        else
            textRight(v and "ON" or "OFF", x + W - 10, ry, v and HOT or DIM)
        end
    end

    local fy = y + H - 16
    rect(x + 10, fy - 4, W - 20, 1, TRACK)
    text("Up/Down select   Left/Right adjust   Esc close", x + 10, fy, DIM)
end

local function drawToast(s)
    local W, H = 150, 28
    local x = math.floor((Isaac.GetScreenWidth() - W) / 2)
    local y = 12
    rect(x, y, W, H, BG)
    rect(x, y, 2, H, ACCENT)
    text(s.name, x + 10, y + 4, TEXT)
    textRight(label(cfg[s.key]), x + W - 8, y + 4, HOT)
    bar(x + 10, y + 19, W - 18, cfg[s.key])
end

local function pressed(key)
    return Input.IsButtonTriggered(key, 0)
end

-- Like pressed, but fires again every REPEAT ms after the key is held for DELAY ms.
local DELAY, REPEAT = 350, 50
local nextRepeat = {}
local function held(key)
    if pressed(key) then
        nextRepeat[key] = Isaac.GetTime() + DELAY
        return true
    end
    local t = nextRepeat[key]
    if t and Input.IsButtonPressed(key, 0) and Isaac.GetTime() >= t then
        nextRepeat[key] = t + REPEAT
        return true
    end
    return false
end

local swallowEsc = false

mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    if swallowEsc and not Input.IsButtonPressed(Keyboard.KEY_ESCAPE, 0) then swallowEsc = false end
    if game:IsPaused() or (ModConfigMenu and ModConfigMenu.IsVisible) then return end
    if pressed(Keyboard.KEY_BACKSLASH) then open = not open end
    if open and pressed(Keyboard.KEY_ESCAPE) then
        open, swallowEsc = false, true
    end

    if open then
        if held(Keyboard.KEY_UP) then sel = (sel - 2) % #settings + 1 end
        if held(Keyboard.KEY_DOWN) then sel = sel % #settings + 1 end
        local s = settings[sel]
        if type(cfg[s.key]) == "number" then
            local dir = (held(Keyboard.KEY_RIGHT) and 1 or 0) - (held(Keyboard.KEY_LEFT) and 1 or 0)
            if dir ~= 0 then set(s.key, cfg[s.key] + dir * STEP) end
        elseif pressed(Keyboard.KEY_RIGHT) or pressed(Keyboard.KEY_LEFT) then
            set(s.key, not cfg[s.key])
        end
        drawPanel()
        return
    end

    -- [ and ] adjust whichever rule is active right now.
    local dir = (pressed(Keyboard.KEY_RIGHT_BRACKET) and 1 or 0) - (pressed(Keyboard.KEY_LEFT_BRACKET) and 1 or 0)
    if dir ~= 0 then
        toast = current()
        set(toast.key, cfg[toast.key] + dir * STEP)
        toastUntil = Isaac.GetTime() + 1500
    end
    if toast and Isaac.GetTime() < toastUntil then drawToast(toast) end
end)

-- Arrow keys shoot by default, so stop shooting while the panel is open (you can still walk).
-- Esc closes the panel, so it must not also open the pause menu until it is released.
local BLOCKED = {
    [ButtonAction.ACTION_SHOOTLEFT] = true,
    [ButtonAction.ACTION_SHOOTRIGHT] = true,
    [ButtonAction.ACTION_SHOOTUP] = true,
    [ButtonAction.ACTION_SHOOTDOWN] = true,
    [ButtonAction.ACTION_PAUSE] = true,
    [ButtonAction.ACTION_MENUBACK] = true,
}
mod:AddCallback(ModCallbacks.MC_INPUT_ACTION, function(_, _, hook, action)
    if (open or swallowEsc) and BLOCKED[action] then
        if hook == InputHook.GET_ACTION_VALUE then return 0 end
        return false
    end
end)

if ModConfigMenu then
    local CAT = "Speedup"
    if ModConfigMenu.GetCategoryIDByName(CAT) ~= nil then
        ModConfigMenu.RemoveCategory(CAT)
    end
    for _, s in ipairs(settings) do
        local numeric = type(s.default) == "number"
        ModConfigMenu.AddSetting(CAT, {
            Type = numeric and ModConfigMenu.OptionType.NUMBER or ModConfigMenu.OptionType.BOOLEAN,
            Minimum = MIN,
            Maximum = MAX,
            ModifyBy = STEP,
            Default = s.default,
            CurrentSetting = function() return cfg[s.key] end,
            Display = function()
                local v = cfg[s.key]
                return s.name .. ": " .. (numeric and label(v) or (v and "on" or "off"))
            end,
            OnChange = function(v) set(s.key, v) end,
            Info = { s.info },
        })
    end
end
