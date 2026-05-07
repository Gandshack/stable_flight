-- stable_flight.lua
-- Flight stabilizer

local CONFIG_FILE = "stable_flight.cfg"
local POSITIONS   = { "front_left", "front_right", "back_left", "back_right" }

local w, h        = term.getSize()
local mainWin     = window.create(term.current(), 1, 1, w, h - 1)
local cmdWin      = window.create(term.current(), 1, h, w, 1)

-- ============================================================
-- Config persistence
-- ============================================================
local config      = {
    relays     = {
        front_left  = nil,
        front_right = nil,
        back_left   = nil,
        back_right  = nil,
    },
    side       = "top",
    hoverPower = 8,
    kP         = 0.3,
}

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(config))
    f.close()
end

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then return end
    local f = fs.open(CONFIG_FILE, "r")
    local data = textutils.unserialize(f.readAll())
    f.close()
    if data then
        for k, v in pairs(data) do config[k] = v end
    end
end

loadConfig()

-- ============================================================
-- Helpers
-- ============================================================
local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function status(msg, duration)
    term.redirect(cmdWin)
    term.clear()
    term.setCursorPos(1, 1)
    term.write(msg)
    term.redirect(term.native())
    sleep(duration or 1)
end

-- ============================================================
-- Peripheral discovery
-- ============================================================
local function findGimbal()
    return peripheral.find("gimbal_sensor")
end

local function listRelays()
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "redstone_relay" then
            table.insert(names, name)
        end
    end
    table.sort(names, function(a, b)
        local na = tonumber(a:match("(%d+)$")) or 0
        local nb = tonumber(b:match("(%d+)$")) or 0
        return na < nb
    end)
    return names
end

-- ============================================================
-- Stabilizer
-- ============================================================
local function setThrust(relayName, power)
    if not relayName then return end
    local relay = peripheral.wrap(relayName)
    if not relay then return end
    relay.setAnalogOutput(config.side, clamp(math.floor(power + 0.5), 0, 15))
end

local function allOff()
    for _, name in pairs(config.relays) do
        if name then
            local r = peripheral.wrap(name)
            if r then r.setAnalogOutput(config.side, 0) end
        end
    end
end

-- Main view: shows live config / status. Re-rendered any time it could change.
local function drawMain(extra)
    term.redirect(mainWin)
    term.clear()
    term.setCursorPos(1, 1)
    term.write("=== Stable Flight ===")

    term.setCursorPos(1, 3)
    term.write("Thruster relays:")
    for i, pos in ipairs(POSITIONS) do
        term.setCursorPos(1, 3 + i)
        term.write(string.format("  %-12s = %s", pos, config.relays[pos] or "<unset>"))
    end

    term.setCursorPos(1, 9)
    term.write(string.format("Hover power : %d", config.hoverPower))
    term.setCursorPos(1, 10)
    term.write(string.format("Gain (kP)   : %.2f", config.kP))
    term.setCursorPos(1, 11)
    term.write(string.format("Output side : %s", config.side))

    term.setCursorPos(1, 13)
    term.write("Type 'help' for commands.")

    if extra then
        term.setCursorPos(1, 15)
        term.write(extra)
    end

    term.redirect(term.native())
end

-- ============================================================
-- Scrollable views (chest-browser pattern)
-- ============================================================
local function showHelp()
    local lines = {
        "Commands:",
        "  q, quit          - exit program",
        "  help             - show this help",
        "  list             - list available relays",
        "  show             - show current config",
        "  perf             - list all peripherals",
        "  set <pos> <num>  - assign relay to position",
        "                     pos: front_left, front_right,",
        "                          back_left, back_right",
        "  pulse <pos>      - test a position",
        "  power <0-15>     - set hover power",
        "  gain <number>    - set proportional gain",
        "  side <up|down|.> - set output redstone side",
        "  start            - start stabilizer",
        "",
        "Press any key to return...",
    }
    term.redirect(mainWin)
    term.clear()
    for i, line in ipairs(lines) do
        term.setCursorPos(1, i)
        term.write(line)
    end
    term.redirect(term.native())
    os.pullEvent("key")
end

local function showRelays()
    local relays = listRelays()
    if #relays == 0 then
        status("No relays found on the network.", 2)
        return
    end

    local offset = 0
    local maxOff = math.max(0, #relays - (h - 2))

    -- Find which relays are currently assigned (for marking)
    local assigned = {}
    for pos, name in pairs(config.relays) do
        if name then assigned[name] = pos end
    end

    local function draw()
        term.redirect(mainWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write(string.format("Relays (%d)  (* = assigned)", #relays))
        for y = 2, h - 1 do
            local idx = y - 1 + offset
            local name = relays[idx]
            term.setCursorPos(1, y)
            if name then
                local marker = assigned[name] and "*" or " "
                local label = assigned[name] and (" -> " .. assigned[name]) or ""
                term.write(string.format("%s%2d. %s%s", marker, idx, name, label))
            end
        end
        term.redirect(cmdWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Scroll or press any key...")
        term.redirect(term.native())
    end

    draw()
    while true do
        local event, p1 = os.pullEvent()
        if event == "mouse_scroll" then
            offset = math.max(0, math.min(offset + p1, maxOff))
            draw()
        elseif event == "key" then
            return
        end
    end
end

local function listPeripherals()
    local all = {}
    for _, name in ipairs(peripheral.getNames()) do
        table.insert(all, { name = name, ptype = peripheral.getType(name) })
    end
    table.sort(all, function(a, b) return a.name < b.name end)

    if #all == 0 then
        status("No peripherals found!", 2)
        return
    end

    local offset = 0
    local maxOff = math.max(0, #all - (h - 2))

    local function draw()
        term.redirect(mainWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write(string.format("All peripherals (%d)", #all))
        for y = 2, h - 1 do
            local idx = y - 1 + offset
            local entry = all[idx]
            term.setCursorPos(1, y)
            if entry then
                term.write(string.format("  %s [%s]", entry.name, entry.ptype or "?"))
            end
        end
        term.redirect(cmdWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Scroll or press any key...")
        term.redirect(term.native())
    end

    draw()
    while true do
        local event, p1 = os.pullEvent()
        if event == "mouse_scroll" then
            offset = math.max(0, math.min(offset + p1, maxOff))
            draw()
        elseif event == "key" then
            return
        end
    end
end

-- ============================================================
-- Stabilizer (its own view)
-- ============================================================
local function stabilize()
    local gimbal = findGimbal()
    if not gimbal then
        status("No gimbal sensor found!", 2)
        return
    end

    for pos, name in pairs(config.relays) do
        if not name then
            status("'" .. pos .. "' not set!", 2)
            return
        end
    end

    local function drawStat(pitch, roll, fl, fr, bl, br)
        term.redirect(mainWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("=== STABILIZING ===")
        term.setCursorPos(1, 3)
        term.write(string.format("Pitch (X): %7.2f", pitch))
        term.setCursorPos(1, 4)
        term.write(string.format("Roll  (Z): %7.2f", roll))
        term.setCursorPos(1, 6)
        term.write("Thrust output (0-15):")
        term.setCursorPos(1, 7)
        term.write(string.format("  FL: %2d   FR: %2d", fl, fr))
        term.setCursorPos(1, 8)
        term.write(string.format("  BL: %2d   BR: %2d", bl, br))
        term.redirect(cmdWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Press any key to stop")
        term.redirect(term.native())
    end

    while true do
        local timer = os.startTimer(0.05)
        while true do
            local event, p1 = os.pullEvent()
            if event == "key" then
                allOff()
                status("Stopped.", 1)
                return
            elseif event == "timer" and p1 == timer then
                break
            end
        end

        local angles = gimbal.getAngles()
        local pitch  = angles[1]
        local roll   = angles[2]

        local pc     = pitch * config.kP
        local rc     = roll * config.kP

        local fl     = clamp(math.floor(config.hoverPower - pc - rc + 0.5), 0, 15)
        local fr     = clamp(math.floor(config.hoverPower - pc + rc + 0.5), 0, 15)
        local bl     = clamp(math.floor(config.hoverPower + pc - rc + 0.5), 0, 15)
        local br     = clamp(math.floor(config.hoverPower + pc + rc + 0.5), 0, 15)

        setThrust(config.relays.front_left, fl)
        setThrust(config.relays.front_right, fr)
        setThrust(config.relays.back_left, bl)
        setThrust(config.relays.back_right, br)

        drawStat(pitch, roll, fl, fr, bl, br)
    end
end

-- ============================================================
-- Commands
-- ============================================================
local function setRelay(pos, num)
    local relays = listRelays()
    local relay = relays[num]
    if not relay then
        status("No relay #" .. tostring(num), 2)
        return
    end
    config.relays[pos] = relay
    saveConfig()
    status("Set " .. pos .. " = " .. relay, 1)
end

local function pulse(pos)
    local name = config.relays[pos]
    if not name then
        status("Not set: " .. pos, 2); return
    end
    local r = peripheral.wrap(name)
    if not r then
        status("Can't wrap " .. name, 2); return
    end
    r.setAnalogOutput(config.side, 15)
    status("Pulsing " .. pos .. "...", 0)
    sleep(2)
    r.setAnalogOutput(config.side, 0)
    status("Done.", 1)
end

local function handleCommand(cmd)
    if cmd == "q" or cmd == "quit" then
        term.clear()
        term.setCursorPos(1, 1)
        return false
    elseif cmd == "help" then
        showHelp()
    elseif cmd == "list" then
        showRelays()
    elseif cmd == "show" then
        -- main view already shows config; just refresh
        status("Config shown above.", 1)
    elseif cmd == "perf" then
        listPeripherals()
    elseif cmd == "start" then
        stabilize()
    elseif cmd == "push" then
        -- nothing here; placeholder for parity with chesty
    elseif cmd:match("^set ") then
        local a, b = cmd:match("^set (%S+) (%S+)$")
        local num = tonumber(b)
        local validPos = {}
        for _, p in ipairs(POSITIONS) do validPos[p] = true end
        if not a or not validPos[a] then
            status("Unknown pos. front_left/right, back_left/right", 2)
        elseif not num then
            status("Need a number. Use 'list'.", 2)
        else
            setRelay(a, num)
        end
    elseif cmd:match("^pulse ") then
        local a = cmd:match("^pulse (%S+)$")
        if not a or not config.relays[a] then
            status("Unknown pos.", 2)
        else
            pulse(a)
        end
    elseif cmd:match("^power ") then
        local n = tonumber(cmd:match("^power (%S+)$"))
        if n then
            config.hoverPower = clamp(math.floor(n), 0, 15)
            saveConfig()
            status("Hover power: " .. config.hoverPower, 1)
        else
            status("Usage: power 0-15", 2)
        end
    elseif cmd:match("^gain ") then
        local n = tonumber(cmd:match("^gain (%S+)$"))
        if n then
            config.kP = n
            saveConfig()
            status("kP: " .. config.kP, 1)
        else
            status("Usage: gain <number>", 2)
        end
    elseif cmd:match("^side ") then
        local s = cmd:match("^side (%S+)$")
        if s then
            config.side = s
            saveConfig()
            status("Side: " .. s, 1)
        else
            status("Usage: side <up|down|north|south|east|west>", 2)
        end
    elseif cmd ~= "" then
        status("Unknown command. Type 'help'.", 1)
    end
    return true
end

-- ============================================================
-- Main loop (chest-browser style)
-- ============================================================
local cmdInput = ""

local function drawPrompt()
    term.redirect(cmdWin)
    term.clear()
    term.setCursorPos(1, 1)
    term.write(">" .. cmdInput)
    term.redirect(term.native())
end

local function fullDraw()
    drawMain()
    drawPrompt()
end

fullDraw()

while true do
    local event, p1 = os.pullEvent()

    if event == "char" then
        cmdInput = cmdInput .. p1
        drawPrompt()
    elseif event == "key" then
        if p1 == keys.enter then
            if not handleCommand(cmdInput) then break end
            cmdInput = ""
            fullDraw()
        elseif p1 == keys.backspace then
            cmdInput = cmdInput:sub(1, -2)
            drawPrompt()
        end
    end
end
