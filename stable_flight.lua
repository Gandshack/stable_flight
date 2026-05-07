-- stable_flight.lua
-- Flight stabilizer with PD attitude + altitude + velocity hold

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
    velSensors = {
        x = nil, -- peripheral name for X-axis (sideways) velocity
        z = nil, -- peripheral name for Z-axis (forward/back) velocity
    },
    side       = "top",
    hoverPower = 4.3,
    kP         = 0.2,
    kD         = 1.0,
    altKP      = 0.5,
    altKD      = 2.0,
    altMax     = 4,
    targetAlt  = nil,
    -- Velocity outer loop
    velKP      = 5.0,  -- velocity error -> target lean angle (degrees)
    velKD      = 2.0,  -- velocity rate damping
    maxLean    = 20,   -- max angle (deg) the velocity loop can command
    targetVelX = 0,
    targetVelZ = 0,
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
    if data then for k, v in pairs(data) do config[k] = v end end
    -- Migrations for old configs
    if config.kD == nil then config.kD = 1.0 end
    if config.altKP == nil then config.altKP = 0.5 end
    if config.altKD == nil then config.altKD = 2.0 end
    if config.altMax == nil then config.altMax = 4 end
    if config.velKP == nil then config.velKP = 5.0 end
    if config.velKD == nil then config.velKD = 2.0 end
    if config.maxLean == nil then config.maxLean = 20 end
    if config.targetVelX == nil then config.targetVelX = 0 end
    if config.targetVelZ == nil then config.targetVelZ = 0 end
    if config.velSensors == nil then config.velSensors = { x = nil, z = nil } end
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

local function listVelSensors()
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "velocity_sensor" then
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

local function drawMain()
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

    term.setCursorPos(1, 8)
    term.write("Velocity sensors:")
    term.setCursorPos(1, 9)
    term.write(string.format("  %-3s = %s", "x", config.velSensors.x or "<unset>"))
    term.setCursorPos(1, 10)
    term.write(string.format("  %-3s = %s", "z", config.velSensors.z or "<unset>"))

    term.setCursorPos(1, 12)
    term.write(string.format("Hover power : %.2f", config.hoverPower))
    term.setCursorPos(1, 13)
    term.write(string.format("Tilt P/D    : %.2f / %.2f", config.kP, config.kD))
    term.setCursorPos(1, 14)
    term.write(string.format("Alt  P/D    : %.2f / %.2f  max %d",
        config.altKP, config.altKD, config.altMax))
    term.setCursorPos(1, 15)
    term.write(string.format("Vel  P/D    : %.2f / %.2f  lean %d",
        config.velKP, config.velKD, config.maxLean))

    term.setCursorPos(1, 17)
    term.write(string.format("Target alt : %s",
        config.targetAlt and string.format("%.2f", config.targetAlt) or "<auto>"))
    term.setCursorPos(1, 18)
    term.write(string.format("Target vel : x=%.2f  z=%.2f",
        config.targetVelX, config.targetVelZ))

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

    local velX, velZ
    if config.velSensors.x then velX = peripheral.wrap(config.velSensors.x) end
    if config.velSensors.z then velZ = peripheral.wrap(config.velSensors.z) end
    if not velX or not velZ then
        status("Velocity sensors not assigned! Use setvel.", 2)
        return
    end

    for pos, name in pairs(config.relays) do
        if not name then
            status("'" .. pos .. "' not set!", 2); return
        end
    end

    local targetAlt = config.targetAlt or altimeter.getHeight()

    local lastPitch, lastRoll = 0, 0
    local lastAlt = altimeter.getHeight()
    local lastVX, lastVZ = velX.getVelocity(), velZ.getVelocity()
    local firstTick = true

    local accum = { fl = 0, fr = 0, bl = 0, br = 0 }

    local function dither(name, key, power)
        accum[key] = accum[key] + power
        local whole = math.floor(accum[key] + 0.5)
        accum[key] = accum[key] - whole
        whole = clamp(whole, 0, 15)
        setRawThrust(name, whole)
        return whole
    end

    local function drawStat(pitch, roll, alt, altErr, vx, vz, tgtPitch, tgtRoll,
                            dFL, dFR, dBL, dBR)
        term.redirect(mainWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("=== STABILIZING ===")
        term.setCursorPos(1, 3)
        term.write(string.format("Pitch: %7.2f tgt %+6.2f", pitch, tgtPitch))
        term.setCursorPos(1, 4)
        term.write(string.format("Roll : %7.2f tgt %+6.2f", roll, tgtRoll))
        term.setCursorPos(1, 6)
        term.write(string.format("Alt  : %7.2f tgt %7.2f", alt, targetAlt))
        term.setCursorPos(1, 7)
        term.write(string.format("AErr : %+6.2f", altErr))
        term.setCursorPos(1, 9)
        term.write(string.format("VelX : %+6.2f tgt %+5.2f", vx, config.targetVelX))
        term.setCursorPos(1, 10)
        term.write(string.format("VelZ : %+6.2f tgt %+5.2f", vz, config.targetVelZ))
        term.setCursorPos(1, 12)
        term.write("Sent (FL FR BL BR):")
        term.setCursorPos(1, 13)
        term.write(string.format("  %2d  %2d  %2d  %2d", dFL, dFR, dBL, dBR))
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
                allOff(); status("Stopped.", 1); return
            elseif event == "timer" and p1 == timer then
                break
            end
        end

        -- Read sensors
        local angles                                       = gimbal.getAngles()
        local roll                                         = -angles[1]
        local pitch                                        = angles[2]
        local alt                                          = altimeter.getHeight()
        local vx                                           = velX.getVelocity()
        local vz                                           = velZ.getVelocity()

        -- Rates
        local pitchRate, rollRate, altRate, vxRate, vzRate = 0, 0, 0, 0, 0
        if not firstTick then
            pitchRate = pitch - lastPitch
            rollRate  = roll - lastRoll
            altRate   = alt - lastAlt
            vxRate    = vx - lastVX
            vzRate    = vz - lastVZ
        end
        firstTick      = false
        lastPitch      = pitch; lastRoll = roll; lastAlt = alt
        lastVX         = vx; lastVZ = vz

        -- ===== OUTER LOOP: velocity -> target attitude =====
        -- Velocity error -> desired lean angle
        -- To accelerate +X, we need to roll a certain way; to accelerate +Z, pitch.
        -- Sign convention guess: positive vel error -> positive lean.
        -- If craft accelerates wrong way, flip sign of velKP/velKD or swap sensor axes.
        local vxErr    = config.targetVelX - vx
        local vzErr    = config.targetVelZ - vz

        local tgtRoll  = clamp(
            (vxErr * config.velKP) - (vxRate * config.velKD),
            -config.maxLean, config.maxLean
        )
        local tgtPitch = clamp(
            (vzErr * config.velKP) - (vzRate * config.velKD),
            -config.maxLean, config.maxLean
        )

        -- ===== INNER LOOP: attitude -> thrust =====
        -- Note: error = current - target (not target - current), so when at-target the correction is zero
        local pitchErr = pitch - tgtPitch
        local rollErr  = roll - tgtRoll

        local pc       = (pitchErr * config.kP) + (pitchRate * config.kD)
        local rc       = (rollErr * config.kP) + (rollRate * config.kD)

        -- ===== ALTITUDE LOOP =====
        local altErr   = targetAlt - alt
        local altCorr  = clamp(
            (altErr * config.altKP) - (altRate * config.altKD),
            -config.altMax, config.altMax
        )

        -- ===== MIX =====
        local fl       = clamp(config.hoverPower + altCorr - pc - rc, 0, 15)
        local fr       = clamp(config.hoverPower + altCorr - pc + rc, 0, 15)
        local bl       = clamp(config.hoverPower + altCorr + pc - rc, 0, 15)
        local br       = clamp(config.hoverPower + altCorr + pc + rc, 0, 15)

        local dFL      = dither(config.relays.front_left, "fl", fl)
        local dFR      = dither(config.relays.front_right, "fr", fr)
        local dBL      = dither(config.relays.back_left, "bl", bl)
        local dBR      = dither(config.relays.back_right, "br", br)

        drawStat(pitch, roll, alt, altErr, vx, vz, tgtPitch, tgtRoll, dFL, dFR, dBL, dBR)
    end
end

-- ============================================================
-- Scrollable views
-- ============================================================
local function showHelp()
    local lines = {
        "Commands:",
        "  q, quit            - exit",
        "  help               - this help",
        "  list               - list relays",
        "  vlist              - list velocity sensors",
        "  perf               - list all peripherals",
        "  set <pos> <num>    - assign relay",
        "  setvel <axis> <n>  - assign vel sensor (axis=x|z)",
        "  pulse <pos>        - test thruster",
        "  power <num>        - hover power (decimals OK)",
        "  gain <num>         - tilt P gain",
        "  dgain <num>        - tilt D gain",
        "  altgain <num>      - alt P gain",
        "  altdgain <num>     - alt D gain",
        "  altmax <num>       - max alt correction",
        "  velgain <num>      - vel P gain",
        "  veldgain <num>     - vel D gain",
        "  maxlean <num>      - max lean angle (deg)",
        "  target <Y>|auto    - target altitude",
        "  velx <num>         - target X velocity",
        "  velz <num>         - target Z velocity",
        "  hover              - velx 0, velz 0",
        "  side <side>        - relay output side",
        "  start              - run stabilizer",
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

local function showScrollList(title, items, render)
    if #items == 0 then
        status("Nothing to show.", 2); return
    end

    local offset = 0
    local maxOff = math.max(0, #items - (h - 2))

    local function draw()
        term.redirect(mainWin)
        term.clear()
        term.setCursorPos(1, 1)
        term.write(title)
        for y = 2, h - 1 do
            local idx = y - 1 + offset
            local item = items[idx]
            term.setCursorPos(1, y)
            if item then term.write(render(item, idx)) end
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
    local assigned = {}
    for pos, name in pairs(config.relays) do
        if name then assigned[name] = pos end
    end
    showScrollList(
        string.format("Relays (%d)  (* = assigned)", #relays),
        relays,
        function(name, idx)
            local marker = assigned[name] and "*" or " "
            local label = assigned[name] and (" -> " .. assigned[name]) or ""
            return string.format("%s%2d. %s%s", marker, idx, name, label)
        end
    )
end

local function showVelSensors()
    local sensors = listVelSensors()
    local assigned = {}
    if config.velSensors.x then assigned[config.velSensors.x] = "x" end
    if config.velSensors.z then assigned[config.velSensors.z] = "z" end
    showScrollList(
        string.format("Velocity sensors (%d)  (* = assigned)", #sensors),
        sensors,
        function(name, idx)
            local marker = assigned[name] and "*" or " "
            local label = assigned[name] and (" -> " .. assigned[name]) or ""
            return string.format("%s%2d. %s%s", marker, idx, name, label)
        end
    )
end

local function listPeripherals()
    local all = {}
    for _, name in ipairs(peripheral.getNames()) do
        table.insert(all, { name = name, ptype = peripheral.getType(name) })
    end
    table.sort(all, function(a, b) return a.name < b.name end)
    showScrollList(
        string.format("All peripherals (%d)", #all),
        all,
        function(e, idx) return string.format("  %s [%s]", e.name, e.ptype or "?") end
    )
end

-- ============================================================
-- Commands
-- ============================================================
local function setRelay(pos, num)
    local relays = listRelays()
    local relay = relays[num]
    if not relay then
        status("No relay #" .. tostring(num), 2); return
    end
    config.relays[pos] = relay
    saveConfig()
    status("Set " .. pos .. " = " .. relay, 1)
end

local function setVelSensor(axis, num)
    local sensors = listVelSensors()
    local sensor = sensors[num]
    if not sensor then
        status("No vel sensor #" .. tostring(num), 2); return
    end
    config.velSensors[axis] = sensor
    saveConfig()
    status("Set vel " .. axis .. " = " .. sensor, 1)
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

local function setNumberConfig(key, n, label)
    if n then
        config[key] = n; saveConfig(); status(label .. ": " .. n, 1)
    else
        status("Need a number", 2)
    end
end

local function handleCommand(cmd)
    if cmd == "q" or cmd == "quit" then
        term.clear(); term.setCursorPos(1, 1); return false
    elseif cmd == "help" then
        showHelp()
    elseif cmd == "list" then
        showRelays()
    elseif cmd == "vlist" then
        showVelSensors()
    elseif cmd == "perf" then
        listPeripherals()
    elseif cmd == "start" then
        stabilize()
    elseif cmd == "hover" then
        config.targetVelX = 0; config.targetVelZ = 0
        saveConfig()
        status("Hover targets set (vel x=0 z=0)", 1)
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
    elseif cmd:match("^setvel ") then
        local a, b = cmd:match("^setvel (%S+) (%S+)$")
        local num = tonumber(b)
        if a ~= "x" and a ~= "z" then
            status("Axis must be x or z", 2)
        elseif not num then
            status("Need a number. Use 'vlist'.", 2)
        else
            setVelSensor(a, num)
        end
    elseif cmd:match("^pulse ") then
        local a = cmd:match("^pulse (%S+)$")
        if not a or not isValidPosition(a) then
            status("Unknown pos.", 2)
        else
            pulse(a)
        end
    elseif cmd:match("^power ") then
        setNumberConfig("hoverPower", tonumber(cmd:match("^power (%S+)$")), "Hover power")
    elseif cmd:match("^gain ") then
        setNumberConfig("kP", tonumber(cmd:match("^gain (%S+)$")), "kP")
    elseif cmd:match("^dgain ") then
        setNumberConfig("kD", tonumber(cmd:match("^dgain (%S+)$")), "kD")
    elseif cmd:match("^altgain ") then
        setNumberConfig("altKP", tonumber(cmd:match("^altgain (%S+)$")), "altKP")
    elseif cmd:match("^altdgain ") then
        setNumberConfig("altKD", tonumber(cmd:match("^altdgain (%S+)$")), "altKD")
    elseif cmd:match("^altmax ") then
        setNumberConfig("altMax", tonumber(cmd:match("^altmax (%S+)$")), "altMax")
    elseif cmd:match("^velgain ") then
        setNumberConfig("velKP", tonumber(cmd:match("^velgain (%S+)$")), "velKP")
    elseif cmd:match("^veldgain ") then
        setNumberConfig("velKD", tonumber(cmd:match("^veldgain (%S+)$")), "velKD")
    elseif cmd:match("^maxlean ") then
        setNumberConfig("maxLean", tonumber(cmd:match("^maxlean (%S+)$")), "maxLean")
    elseif cmd:match("^velx ") then
        setNumberConfig("targetVelX", tonumber(cmd:match("^velx (%S+)$")), "targetVelX")
    elseif cmd:match("^velz ") then
        setNumberConfig("targetVelZ", tonumber(cmd:match("^velz (%S+)$")), "targetVelZ")
    elseif cmd:match("^target ") then
        local arg = cmd:match("^target (%S+)$")
        if arg == "auto" then
            config.targetAlt = nil; saveConfig()
            status("Target: auto", 1)
        else
            local n = tonumber(arg)
            if n then
                config.targetAlt = n; saveConfig(); status("Target alt: " .. n, 1)
            else
                status("Usage: target <Y> | target auto", 2)
            end
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
