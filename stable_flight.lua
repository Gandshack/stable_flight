-- stable_flight.lua
-- Flight stabilizer with PD attitude + altitude hold

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
    hoverPower = 4.3,
    kP         = 0.2,
    kD         = 1.0,
    altKP      = 0.5,
    altKD      = 2.0,
    altMax     = 4,
    targetAlt  = nil, -- nil = use current altitude on start
    pitchTrim  = 0,
    rollTrim   = 0,
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
    if config.kD == nil then config.kD = 1.0 end
    if config.altKP == nil then config.altKP = 0.5 end
    if config.altKD == nil then config.altKD = 2.0 end
    if config.altMax == nil then config.altMax = 4 end
    if config.pitchTrim == nil then config.pitchTrim = 0 end
    if config.rollTrim == nil then config.rollTrim = 0 end
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

local function isValidPosition(p)
    for _, pos in ipairs(POSITIONS) do
        if pos == p then return true end
    end
    return false
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

local function findAltimeter()
    return peripheral.find("altitude_sensor")
end

local function findOpticalSensor()
    return peripheral.find("optical_sensor")
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
local function setRawThrust(relayName, level)
    if not relayName then return end
    local relay = peripheral.wrap(relayName)
    if not relay then return end
    relay.setAnalogOutput(config.side, clamp(level, 0, 15))
end

local function allOff()
    for _, name in pairs(config.relays) do
        if name then
            local r = peripheral.wrap(name)
            if r then r.setAnalogOutput(config.side, 0) end
        end
    end
end

local mainScroll = 0

local function buildMainLines()
    local lines = { "=== Stable Flight ===", "", "Thruster relays:" }
    for _, pos in ipairs(POSITIONS) do
        table.insert(lines, string.format("  %-12s = %s", pos, config.relays[pos] or "<unset>"))
    end
    table.insert(lines, "")
    table.insert(lines, string.format("Hover power : %.2f", config.hoverPower))
    table.insert(lines, string.format("Tilt P/D    : %.2f / %.2f", config.kP, config.kD))
    table.insert(lines, string.format("Alt  P/D    : %.2f / %.2f", config.altKP, config.altKD))
    table.insert(lines, string.format("Alt max     : %d", config.altMax))
    table.insert(lines, string.format("Target alt  : %s",
        config.targetAlt and string.format("%.2f", config.targetAlt) or "<auto>"))
    table.insert(lines, string.format("Output side : %s", config.side))
    table.insert(lines, string.format("Trim P/R    : %+.2f / %+.2f", config.pitchTrim, config.rollTrim))
    table.insert(lines, "")
    table.insert(lines, "Type 'help' for commands.")
    return lines
end

local function drawMain()
    local lines  = buildMainLines()
    local maxOff = math.max(0, #lines - (h - 1))
    if mainScroll > maxOff then mainScroll = maxOff end

    term.redirect(mainWin)
    term.clear()
    for y = 1, h - 1 do
        local line = lines[y + mainScroll]
        term.setCursorPos(1, y)
        if line then term.write(line) end
    end
    term.redirect(term.native())
end

local cmdInput = ""

local function drawPrompt()
    term.redirect(cmdWin)
    term.clear()
    term.setCursorPos(1, 1)
    term.write(">" .. cmdInput)
    term.redirect(term.native())
end

local function stabilize()
    local gimbal = findGimbal()
    if not gimbal then
        status("No gimbal sensor found!", 2); return
    end

    local altimeter = findAltimeter()
    if not altimeter then
        status("No altitude sensor found!", 2); return
    end

    local sensor = findOpticalSensor() -- optional, needed for landing

    for pos, name in pairs(config.relays) do
        if not name then
            status("'" .. pos .. "' not set!", 2); return
        end
    end

    local targetAlt      = config.targetAlt or altimeter.getHeight()
    local landing        = false
    local LAND_DIST      = 2.0 -- cut thrust when sensor reads this close
    local DESCENT_RATE   = 0.3 -- blocks per tick to lower targetAlt when landing
    local flightMsg      = ""
    local flightMsgTicks = 0

    local function showFlightMsg(msg, ticks)
        flightMsg      = msg
        flightMsgTicks = ticks or 20 -- default ~1 second at 20hz
    end

    local lastPitch, lastRoll = 0, 0
    local lastAlt             = altimeter.getHeight()
    local firstTick           = true
    local accum               = { fl = 0, fr = 0, bl = 0, br = 0 }

    -- Speed / climb tracking
    local startTime           = os.clock()
    local startAlt            = altimeter.getHeight()
    local maxAltSpeed         = 0 -- blocks/sec
    local currentSpeed        = 0 -- blocks/sec
    local arrivedShown        = false

    local function dither(name, key, power)
        accum[key]  = accum[key] + power
        local whole = math.floor(accum[key] + 0.5)
        accum[key]  = accum[key] - whole
        whole       = clamp(whole, 0, 15)
        setRawThrust(name, whole)
        return whole
    end

    local function drawStat(pitch, roll, pRate, rRate, alt, altErr, altRate, altCorr,
                            dFL, dFR, dBL, dBR)
        local dist = sensor and sensor.getDistance() or nil
        term.redirect(mainWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write(landing and "=== LANDING ===" or "=== STABILIZING ===")
        term.setCursorPos(1, 3)
        term.write(string.format("Pitch: %7.2f rate %+5.2f", pitch, pRate))
        term.setCursorPos(1, 4)
        term.write(string.format("Roll : %7.2f rate %+5.2f", roll, rRate))
        term.setCursorPos(1, 6)
        term.write(string.format("Alt  : %7.2f tgt %7.2f", alt, targetAlt))
        term.setCursorPos(1, 7)
        term.write(string.format("AErr : %+6.2f rate %+5.2f", altErr, altRate))
        term.setCursorPos(1, 8)
        term.write(string.format("AltCorr: %+5.2f", altCorr))
        term.setCursorPos(1, 9)
        term.write(string.format("Speed  : %+6.1f  max %5.1f blk/s", currentSpeed, maxAltSpeed))
        if dist then
            term.setCursorPos(1, 10)
            term.write(string.format("Sensor : %.2f blk", dist))
        end
        if flightMsg ~= "" then
            term.setCursorPos(1, 11)
            term.write(flightMsg)
        end
        term.setCursorPos(1, 12)
        term.write("Sent (FL FR BL BR):")
        term.setCursorPos(1, 13)
        term.write(string.format("  %2d  %2d  %2d  %2d", dFL, dFR, dBL, dBR))
        term.redirect(term.native())
    end

    -- Commands available while flying
    local function handleFlightCmd(cmd)
        if cmd == "stop" or cmd == "q" or cmd == "quit" then
            return "stop"
        elseif cmd == "land" then
            if not sensor then
                showFlightMsg("No optical sensor!", 30)
            else
                landing = true
            end
        elseif cmd == "speed" then
            showFlightMsg(string.format("Spd %+.1f  max %.1f blk/s", currentSpeed, maxAltSpeed), 60)
        elseif cmd:match("^target ") then
            local arg = cmd:match("^target (%S+)$")
            local n   = tonumber(arg)
            if n then
                targetAlt    = n
                startTime    = os.clock()
                startAlt     = altimeter.getHeight()
                maxAltSpeed  = 0
                arrivedShown = false
            end
        elseif cmd:match("^ptrim ") then
            local n = tonumber(cmd:match("^ptrim (%S+)$"))
            if n then
                config.pitchTrim = n; saveConfig()
            end
        elseif cmd:match("^rtrim ") then
            local n = tonumber(cmd:match("^rtrim (%S+)$"))
            if n then
                config.rollTrim = n; saveConfig()
            end
        elseif cmd:match("^power ") then
            local n = tonumber(cmd:match("^power (%S+)$"))
            if n then
                config.hoverPower = clamp(n, 0, 15); saveConfig()
            end
        elseif cmd:match("^gain ") then
            local n = tonumber(cmd:match("^gain (%S+)$"))
            if n then
                config.kP = n; saveConfig()
            end
        elseif cmd:match("^dgain ") then
            local n = tonumber(cmd:match("^dgain (%S+)$"))
            if n then
                config.kD = n; saveConfig()
            end
        elseif cmd:match("^altgain ") then
            local n = tonumber(cmd:match("^altgain (%S+)$"))
            if n then
                config.altKP = n; saveConfig()
            end
        elseif cmd:match("^altdgain ") then
            local n = tonumber(cmd:match("^altdgain (%S+)$"))
            if n then
                config.altKD = n; saveConfig()
            end
        elseif cmd:match("^altmax ") then
            local n = tonumber(cmd:match("^altmax (%S+)$"))
            if n then
                config.altMax = n; saveConfig()
            end
        end
        return "continue"
    end

    drawPrompt()

    while true do
        local timer = os.startTimer(0.05)
        while true do
            local event, p1 = os.pullEvent()
            if event == "char" then
                cmdInput = cmdInput .. p1
                drawPrompt()
            elseif event == "key" then
                if p1 == keys.enter then
                    local result = handleFlightCmd(cmdInput)
                    cmdInput = ""
                    if result == "stop" then
                        allOff(); status("Stopped.", 1); return
                    end
                    drawPrompt()
                elseif p1 == keys.backspace then
                    cmdInput = cmdInput:sub(1, -2)
                    drawPrompt()
                end
            elseif event == "timer" and p1 == timer then
                break
            end
        end

        -- Landing: lower target each tick, cut thrust when sensor is close
        if landing then
            local dist = sensor and sensor.getDistance() or nil
            if dist and dist <= LAND_DIST then
                allOff()
                status("Landed!", 2)
                return
            end
            targetAlt = targetAlt - DESCENT_RATE
        end

        local angles                       = gimbal.getAngles()
        local roll                         = -angles[1]
        local pitch                        = angles[2]
        local alt                          = altimeter.getHeight()

        local pitchRate, rollRate, altRate = 0, 0, 0
        if not firstTick then
            pitchRate = pitch - lastPitch
            rollRate  = roll - lastRoll
            altRate   = alt - lastAlt
        end
        firstTick    = false
        lastPitch    = pitch
        lastRoll     = roll
        lastAlt      = alt

        -- Speed tracking (altRate is per tick, *20 = blk/s at 20hz)
        currentSpeed = altRate * 20
        if math.abs(currentSpeed) > maxAltSpeed then
            maxAltSpeed = math.abs(currentSpeed)
        end

        local pc      = ((pitch - config.pitchTrim) * config.kP) + (pitchRate * config.kD)
        local rc      = ((roll - config.rollTrim) * config.kP) + (rollRate * config.kD)

        local altErr  = targetAlt - alt
        local altCorr = clamp(
            (altErr * config.altKP) - (altRate * config.altKD),
            -config.altMax, config.altMax
        )

        -- Arrival detection: first time we get within 3 blocks of target
        if not arrivedShown and not landing and math.abs(altErr) < 3 then
            local elapsed = os.clock() - startTime
            local dist    = math.abs(alt - startAlt)
            showFlightMsg(
                string.format("Arrived! %.1fs  %.0f blk  max %.1f blk/s", elapsed, dist, maxAltSpeed),
                100
            )
            arrivedShown = true
        end

        local fl  = clamp(config.hoverPower + altCorr - pc - rc, 0, 15)
        local fr  = clamp(config.hoverPower + altCorr - pc + rc, 0, 15)
        local bl  = clamp(config.hoverPower + altCorr + pc - rc, 0, 15)
        local br  = clamp(config.hoverPower + altCorr + pc + rc, 0, 15)

        local dFL = dither(config.relays.front_left, "fl", fl)
        local dFR = dither(config.relays.front_right, "fr", fr)
        local dBL = dither(config.relays.back_left, "bl", bl)
        local dBR = dither(config.relays.back_right, "br", br)

        -- Tick down the flight message
        if flightMsgTicks > 0 then
            flightMsgTicks = flightMsgTicks - 1
            if flightMsgTicks == 0 then flightMsg = "" end
        end

        drawStat(pitch, roll, pitchRate, rollRate, alt, altErr, altRate, altCorr,
            dFL, dFR, dBL, dBR)
        drawPrompt()
    end
end

-- ============================================================
-- Scrollable views
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
        "  pulse <pos>      - test a position",
        "  power <num>      - set hover power (decimals OK)",
        "  gain <num>       - set tilt P gain",
        "  dgain <num>      - set tilt D gain",
        "  altgain <num>    - set altitude P gain",
        "  altdgain <num>   - set altitude D gain",
        "  altmax <num>     - max altitude correction",
        "  target <Y>       - set target altitude",
        "  target auto      - capture altitude on start",
        "  side <side>      - set output side",
        "  start            - start stabilizer",
        "  ptrim <num>      - pitch trim (+fwd/-back)",
        "  rtrim <num>      - roll trim (+right/-left)",
        "",
        "In-flight only (type while stabilizing):",
        "  stop             - kill thrust and exit",
        "  land             - auto-land via optical sensor",
        "  target <Y>       - change target altitude live",
        "  (all gain/trim/power commands work too)",
        "",
        "Scroll or press any key to return.",
    }

    local offset = 0
    local maxOff = math.max(0, #lines - (h - 1))

    local function draw()
        term.redirect(mainWin)
        term.clear()
        for y = 1, h - 1 do
            local line = lines[y + offset]
            term.setCursorPos(1, y)
            if line then term.write(line) end
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

local function showRelays()
    local relays = listRelays()
    if #relays == 0 then
        status("No relays found on the network.", 2)
        return
    end

    local offset = 0
    local maxOff = math.max(0, #relays - (h - 2))

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
        term.clear(); term.setCursorPos(1, 1); return false
    elseif cmd == "help" then
        showHelp()
    elseif cmd == "list" then
        showRelays()
    elseif cmd == "show" then
        status("Config shown above.", 1)
    elseif cmd == "perf" then
        listPeripherals()
    elseif cmd == "start" then
        stabilize()
    elseif cmd:match("^set ") then
        local a, b = cmd:match("^set (%S+) (%S+)$")
        local num = tonumber(b)
        if not a or not isValidPosition(a) then
            status("Unknown pos. front_left/right, back_left/right", 2)
        elseif not num then
            status("Need a number. Use 'list'.", 2)
        else
            setRelay(a, num)
        end
    elseif cmd:match("^pulse ") then
        local a = cmd:match("^pulse (%S+)$")
        if not a or not isValidPosition(a) then
            status("Unknown pos.", 2)
        else
            pulse(a)
        end
    elseif cmd:match("^power ") then
        local n = tonumber(cmd:match("^power (%S+)$"))
        if n then
            config.hoverPower = clamp(n, 0, 15); saveConfig()
            status("Hover power: " .. string.format("%.2f", config.hoverPower), 1)
        else
            status("Usage: power 0-15", 2)
        end
    elseif cmd:match("^gain ") then
        local n = tonumber(cmd:match("^gain (%S+)$"))
        if n then
            config.kP = n; saveConfig(); status("kP: " .. n, 1)
        else
            status("Usage: gain <number>", 2)
        end
    elseif cmd:match("^dgain ") then
        local n = tonumber(cmd:match("^dgain (%S+)$"))
        if n then
            config.kD = n; saveConfig(); status("kD: " .. n, 1)
        else
            status("Usage: dgain <number>", 2)
        end
    elseif cmd:match("^altgain ") then
        local n = tonumber(cmd:match("^altgain (%S+)$"))
        if n then
            config.altKP = n; saveConfig(); status("altKP: " .. n, 1)
        else
            status("Usage: altgain <number>", 2)
        end
    elseif cmd:match("^altdgain ") then
        local n = tonumber(cmd:match("^altdgain (%S+)$"))
        if n then
            config.altKD = n; saveConfig(); status("altKD: " .. n, 1)
        else
            status("Usage: altdgain <number>", 2)
        end
    elseif cmd:match("^altmax ") then
        local n = tonumber(cmd:match("^altmax (%S+)$"))
        if n then
            config.altMax = n; saveConfig(); status("altMax: " .. n, 1)
        else
            status("Usage: altmax <number>", 2)
        end
    elseif cmd:match("^target ") then
        local arg = cmd:match("^target (%S+)$")
        if arg == "auto" then
            config.targetAlt = nil
            saveConfig()
            status("Target: auto (use current alt on start)", 1)
        else
            local n = tonumber(arg)
            if n then
                config.targetAlt = n
                saveConfig()
                status("Target altitude: " .. n, 1)
            else
                status("Usage: target <Y> | target auto", 2)
            end
        end
    elseif cmd:match("^ptrim ") then
        local n = tonumber(cmd:match("^ptrim (%S+)$"))
        if n then
            config.pitchTrim = n; saveConfig()
            status("Pitch trim: " .. string.format("%+.2f", n), 1)
        else
            status("Usage: ptrim <number>", 2)
        end
    elseif cmd:match("^rtrim ") then
        local n = tonumber(cmd:match("^rtrim (%S+)$"))
        if n then
            config.rollTrim = n; saveConfig()
            status("Roll trim: " .. string.format("%+.2f", n), 1)
        else
            status("Usage: rtrim <number>", 2)
        end
    elseif cmd:match("^side ") then
        local s = cmd:match("^side (%S+)$")
        if s then
            config.side = s; saveConfig(); status("Side: " .. s, 1)
        else
            status("Usage: side <up|down|...>", 2)
        end
    elseif cmd ~= "" then
        status("Unknown command. Type 'help'.", 1)
    end
    return true
end

-- ============================================================
-- Main loop
-- ============================================================
local function fullDraw()
    drawMain()
    drawPrompt()
end

fullDraw()

while true do
    local event, p1 = os.pullEvent()

    if event == "mouse_scroll" then
        local lines  = buildMainLines()
        local maxOff = math.max(0, #lines - (h - 1))
        mainScroll   = math.max(0, math.min(mainScroll + p1, maxOff))
        drawMain()
    elseif event == "char" then
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
