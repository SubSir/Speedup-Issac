local mod = RegisterMod("Speedup", 1)
local game = Game()
local sfx = SFXManager()
local music = MusicManager()
local json = require("json")

local MIN, MAX, STEP = 100, 300, 5

-- Boss rooms, plus any room with a boss alive in it (boss challenge rooms, Greed in a shop, angels...).
local function isBoss(room)
    local t = room:GetType()
    return t == RoomType.ROOM_BOSS or t == RoomType.ROOM_MINIBOSS or t == RoomType.ROOM_BOSSRUSH
        or room:GetAliveBossesCount() > 0
end

-- Traps never die, so a room with them counts as cleared while they still move, shoot or stab.
local TRAPS = {
    EntityType.ENTITY_POKY, EntityType.ENTITY_WALL_HUGGER, EntityType.ENTITY_SPIKEBALL, EntityType.ENTITY_GRUDGE,
    EntityType.ENTITY_BALL_AND_CHAIN, EntityType.ENTITY_MOCKULUS, EntityType.ENTITY_STONEHEAD,
    EntityType.ENTITY_STONE_EYE, EntityType.ENTITY_CONSTANT_STONE_SHOOTER, EntityType.ENTITY_BRIMSTONE_HEAD,
    EntityType.ENTITY_GAPING_MAW, EntityType.ENTITY_BROKEN_GAPING_MAW, EntityType.ENTITY_QUAKE_GRIMACE,
    EntityType.ENTITY_BOMB_GRIMACE,
}
-- Red (1) and purple (3) fireplaces shoot at you; only while lit. An unlit one stays as a 1 HP stub.
local SHOOTING_FIRES = { 1, 3 }
-- Troll bombs (the smiley ones) go off on their own, so they need dodging too.
local TROLL_BOMBS = { BombVariant.BOMB_TROLL, BombVariant.BOMB_SUPERTROLL, BombVariant.BOMB_GOLDENTROLL }
local trapRoom, gridTraps = false, false

-- On/off spikes are part of the room layout, so the grid only needs scanning on entry.
local function checkGridTraps()
    local room = game:GetRoom()
    for i = 0, room:GetGridSize() - 1 do
        local g = room:GetGridEntity(i)
        if g and g:GetType() == GridEntityType.GRID_SPIKES_ONOFF then gridTraps = true return end
    end
    gridTraps = false
end

local function hasTrapEntity()
    for _, t in ipairs(TRAPS) do
        if #Isaac.FindByType(t) > 0 then return true end
    end
    for _, v in ipairs(TROLL_BOMBS) do
        if #Isaac.FindByType(EntityType.ENTITY_BOMB, v) > 0 then return true end
    end
    for _, v in ipairs(SHOOTING_FIRES) do
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FIREPLACE, v)) do
            if e.HitPoints > 1 then return true end
        end
    end
    return false
end

local function checkTraps()
    trapRoom = gridTraps or hasTrapEntity()
end

-- Speed settings (percent: 100 = vanilla) are rules: the first whose test matches the current room applies.
local settings = {
    { key = "clear", name = "Cleared room", default = 130, test = function(room)
        -- IsClear stays true once cleared, even if spiders pop out of a pot later, so check for enemies too
        return room:IsClear() and not trapRoom and room:GetAliveEnemiesCount() == 0
    end,
      info = "Rooms with no enemies or traps left: exploring, shops, treasure rooms. Trap rooms, and enemies showing up later (spiders from a pot), use Combat." },
    { key = "boss", name = "Boss fight", default = 120, test = isBoss,
      info = "Boss, miniboss and Boss Rush rooms until cleared, and any room while a boss is alive." },
    { key = "combat", name = "Combat", default = 120, test = function() return true end,
      info = "Every other room with enemies." },
    { key = "clock", name = "Real time clock", default = true,
      info = "Shows the real time played this run next to the minimap, so you can see how long a sped-up run really took." },
    { key = "adapt", name = "Learn per room", default = false,
      info = "Each room layout remembers its own speed: +0.05 when you clear it without getting hit, -0.10 when you get hit." },
    { key = "music", name = "Faster music", default = false,
      info = "Music plays faster (and higher pitched) to match game speed." },
    { key = "sfx", name = "Faster sounds", default = false,
      info = "Sound effects play faster (and higher pitched) to match game speed." },
}

local cfg = {}
for _, s in ipairs(settings) do cfg[s.key] = s.default end
cfg.camChecked = false -- Active Cam is switched off once, on the first run with this mod
cfg.rooms = {} -- "Learn per room": speed offset (percent) per room layout, kept across runs
cfg.run = { seed = 0, ms = 0 } -- real time played in the current run, so it survives exit and continue

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

-- A room layout is the same across runs: floor type + room type + layout variant.
local function roomKey()
    local d = game:GetLevel():GetCurrentRoomDesc().Data
    return d and ("%d.%d.%d"):format(d.StageID, d.Type, d.Variant)
end

-- Learned offset for this room; cleared rooms just use their own speed.
local function roomOffset()
    if not cfg.adapt or current().key == "clear" then return 0 end
    return cfg.rooms[roomKey() or ""] or 0
end

local function speedNow()
    return math.max(MIN, math.min(MAX, cfg[current().key] + roomOffset()))
end

local acc, inside = 0, false
local lastTick -- Isaac.GetTime() of the last engine tick, for the real time clock
local owed = 0 -- player updates owed by extra ticks
-- Sound ids with no samples; IsPlaying on them spams "[warn] Sound N has no samples" into log.txt every frame.
local EMPTY_SOUNDS = { [837] = true, [846] = true }
local playing = {}

-- Players update twice per game tick (once inside it, once more on the drawn frame in between), but
-- Game:Update only covers the first, so every extra tick owes each player one more update.
local function payPlayers()
    inside = true
    for i = 0, game:GetNumPlayers() - 1 do Isaac.GetPlayer(i):Update() end
    inside = false
    owed = owed - 1
end

-- Each real 1/30s frame, run (speed - 1) extra full game ticks, so everything keeps its relative timing.
-- LATE so every other mod finishes its POST_UPDATE for this tick before the next one starts.
-- Don't move Game:Update to MC_POST_RENDER to spread ticks over drawn frames: there it blanks whole frames.
-- ponytail: whole ticks per 1/30s, so x2/x3 move evenly and in-between speeds alternate (x1.5 = 1,2,1,2 ticks)
mod:AddPriorityCallback(ModCallbacks.MC_POST_UPDATE, CallbackPriority.LATE, function()
    if inside then return end -- Game:Update fires POST_UPDATE again
    -- Real time only counts while the engine ticks, so pauses and boss intros are left out like the game's timer.
    local now = Isaac.GetTime()
    if lastTick and now - lastTick < 250 then cfg.run.ms = cfg.run.ms + now - lastTick end
    lastTick = now
    if game:GetFrameCount() % 5 == 0 then checkTraps() end -- traps (troll bombs!) come and go mid-room
    while owed > 0 do payPlayers() end -- not paid on a drawn frame (shouldn't happen, but never lose speed)
    local pct = speedNow()
    acc = acc + pct - 100
    inside = true
    while acc >= 100 do
        acc = acc - 100
        game:Update()
        owed = owed + 1
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

-- Pay the owed player updates on the first render after the tick (the tick is already drawn by then), so
-- they show on the next frame alongside the engine's own in-between player update: at x2 every drawn
-- frame moves 2 player updates instead of 3 and 1.
mod:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, CallbackPriority.LATE, function()
    while owed > 0 do payPlayers() end
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
local notice, noticeFor, noticeFrame, noticeUntil = nil, 0, 0, nil

-- The countdown only starts once gameplay runs, so a boss intro or pause doesn't eat the message.
local function showNotice(lines, ms)
    notice, noticeFor, noticeFrame, noticeUntil = lines, ms, game:GetFrameCount(), nil
end

-- Active Cam interpolates the camera from the last two updates, which extra ticks throw off, so it
-- wobbles in big rooms. Turn it off once and say so; if the player turns it back on, leave it be.
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    if cfg.camChecked then return end
    if Options.CameraStyle == 1 then
        Options.CameraStyle = 2
        showNotice({ "Speedup turned off Active Cam: it wobbles when sped up.", "You can turn it back on in Options." }, 8000)
    end
    set("camChecked", true)
end)

-- Learn per room: a hit in the room slows its layout down, a clean clear speeds it up.
local LEARN_UP, LEARN_DOWN, LEARN_LIMIT = 5, 10, 100
local IGNORED_DAMAGE = DamageFlag.DAMAGE_FAKE | DamageFlag.DAMAGE_RED_HEARTS | DamageFlag.DAMAGE_IV_BAG
    | DamageFlag.DAMAGE_NO_PENALTIES | DamageFlag.DAMAGE_CURSED_DOOR -- self-inflicted or harmless
local hit = false

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
    local seed = game:GetSeeds():GetStartSeed()
    if not (continued and cfg.run.seed == seed) then set("run", { seed = seed, ms = 0 }) end
    lastTick = nil
end)

mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function() set("run", cfg.run) end)

mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    set("run", cfg.run) -- save the clock now and then, in case the game closes without exiting the run
    hit = false
    checkGridTraps()
    checkTraps()
    local off = roomOffset()
    if off ~= 0 then -- a learned room plays at its own speed, so say so
        showNotice({ ("This room: %s (%+.2f learned)"):format(label(speedNow()), off / 100) }, 4000)
    end
end)

mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(_, _, _, flags)
    if flags & IGNORED_DAMAGE == 0 then hit = true end
end, EntityType.ENTITY_PLAYER)

mod:AddCallback(ModCallbacks.MC_PRE_SPAWN_CLEAN_AWARD, function()
    local key = roomKey()
    if not cfg.adapt or not key then return end
    local old = cfg.rooms[key] or 0
    local new = math.max(-LEARN_LIMIT, math.min(LEARN_LIMIT, old + (hit and -LEARN_DOWN or LEARN_UP)))
    cfg.rooms[key] = new ~= 0 and new or nil
    set("rooms", cfg.rooms)
    showNotice({ ("This room: %+.2f (%s)"):format(new / 100, hit and "got hit" or "no hit") }, 2500)
end)

local function drawPanel()
    local W, ROW = 256, 16
    local H = 34 + #settings * ROW + 22
    local x = math.floor((Isaac.GetScreenWidth() - W) / 2)
    local y = math.floor((Isaac.GetScreenHeight() - H) / 2)
    local now = current()

    rect(x, y, W, H, BG)
    rect(x, y, W, 2, ACCENT)
    text("SPEEDUP", x + 10, y + 8, HOT)
    local off = roomOffset()
    textRight("now: " .. now.name .. (off ~= 0 and (" %+.2f"):format(off / 100) or ""), x + W - 10, y + 8, DIM)
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

local function drawNotice(lines)
    local W, H = 0, 12 + #lines * 12
    for _, l in ipairs(lines) do W = math.max(W, font:GetStringWidth(l) + 20) end
    local x = math.floor((Isaac.GetScreenWidth() - W) / 2)
    local y = 46
    rect(x, y, W, H, BG)
    rect(x, y, 2, H, ACCENT)
    for i, l in ipairs(lines) do text(l, x + 10, y + 5 + (i - 1) * 12, i == 1 and TEXT or DIM) end
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

-- Just left of the minimap, level with the game's own Time (under the minimap is where curse icons go).
-- Faint like the game's Time, so it's there when you look for it but doesn't draw the eye.
-- ponytail: fixed spot for the default HUD; ignores the HUD offset option
local CLOCK_COLOR = KColor(0.9, 0.88, 0.85, 0.4)
local function drawClock()
    local t = math.floor(cfg.run.ms / 1000)
    local str = ("Real %02d:%02d:%02d"):format(t // 3600, t // 60 % 60, t % 60)
    textRight(str, Isaac.GetScreenWidth() - 86, 33, CLOCK_COLOR)
end

mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    if swallowEsc and not Input.IsButtonPressed(Keyboard.KEY_ESCAPE, 0) then swallowEsc = false end
    if game:IsPaused() or (ModConfigMenu and ModConfigMenu.IsVisible) then return end
    if cfg.clock and game:GetHUD():IsVisible() then drawClock() end
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
    if notice and not noticeUntil and game:GetFrameCount() > noticeFrame then noticeUntil = Isaac.GetTime() + noticeFor end
    if noticeUntil and Isaac.GetTime() < noticeUntil then drawNotice(notice) end
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
