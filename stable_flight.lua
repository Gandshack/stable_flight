-- stable_flight.lua
-- Flight stabilizer

local CONFIG_FILE = "stable_flight.cfg"

-- ============================================================
-- Config persistence
-- ============================================================
local config = {
    relays     = {
        front_left  = nil,
        front_right = nil,
        back_left   = nil,
        back_right  = nil,
    },
    side       = "top", -- which side of relay outputs to thruster
    hoverPower = 8,     -- baseline 0-15
    kP         = 0.3,   -- proportional gain
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
    table.sort(names)
    return names
end

-- ============================================================
-- Stabilizer
-- ============================================================
local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

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

local function stabilize()
    local gimbal = findGimbal()
    if not gimbal then
        print("No gimbal sensor found!")
        return
    end

    -- Verify all 4 relays are configured
    for pos, name in pairs(config.relays) do
        if not name then
            print("Relay '" .. pos .. "' not set. Use: set " .. pos .. " <number>")
            return
        end
    end

    print("Stabilizing. Press any key to stop.")

    while true do
        -- check for key press without blocking
        local timer = os.startTimer(0.05)
        local event, p1 = os.pullEvent()
        if event == "key" then
            allOff()
            print("Stopped.")
            return
        end

        local angles          = gimbal.getAngles()
        local pitch           = angles[1] -- X-axis (forward/back tilt)
        local roll            = angles[2] -- Z-axis (left/right tilt)

        local pitchCorrection = pitch * config.kP
        local rollCorrection  = roll * config.kP

        -- If craft tips FORWARD (nose down), front needs LESS lift, back MORE.
        -- Flip signs here if your contraption corrects backwards.
        setThrust(config.relays.front_left, config.hoverPower - pitchCorrection - rollCorrection)
        setThrust(config.relays.front_right, config.hoverPower - pitchCorrection + rollCorrection)
        setThrust(config.relays.back_left, config.hoverPower + pitchCorrection - rollCorrection)
        setThrust(config.relays.back_right, config.hoverPower + pitchCorrection + rollCorrection)
    end
end

-- ============================================================
-- Commands
-- ============================================================
local POSITIONS = { "front_left", "front_right", "back_left", "back_right" }

local function showRelays()
    local relays = listRelays()
    if #relays == 0 then
        print("No relays found on the network.")
        return
    end
    print("Available relays:")
    for i, name in ipairs(relays) do
        print(string.format("  %d. %s", i, name))
    end
end

local function showConfig()
    print("Current assignments:")
    for _, pos in ipairs(POSITIONS) do
        print(string.format("  %-12s = %s", pos, config.relays[pos] or "<unset>"))
    end
    print(string.format("  hoverPower   = %d", config.hoverPower))
    print(string.format("  kP           = %.2f", config.kP))
    print(string.format("  output side  = %s", config.side))
end

local function setRelay(pos, num)
    local relays = listRelays()
    local relay = relays[num]
    if not relay then
        print("No relay #" .. tostring(num))
        return
    end
    config.relays[pos] = relay
    saveConfig()
    print("Set " .. pos .. " = " .. relay)
end

local function pulse(pos)
    local name = config.relays[pos]
    if not name then
        print("Not set: " .. pos); return
    end
    local r = peripheral.wrap(name)
    if not r then
        print("Can't wrap " .. name); return
    end
    print("Pulsing " .. pos .. " (" .. name .. ")")
    r.setAnalogOutput(config.side, 15)
    sleep(2)
    r.setAnalogOutput(config.side, 0)
end

local function showHelp()
    print("Commands:")
    print("  list                   - list available relays")
    print("  show                   - show current config")
    print("  set <pos> <num>        - assign a relay number to a position")
    print("                           pos = front_left, front_right,")
    print("                                 back_left, back_right")
    print("  pulse <pos>            - test a position by pulsing it")
    print("  power <0-15>           - set hover power")
    print("  gain <number>          - set proportional gain (kP)")
    print("  side <up|down|...>     - set output side")
    print("  start                  - start stabilizer")
    print("  quit                   - exit")
end

-- ============================================================
-- Main loop
-- ============================================================
showHelp()
print()
showConfig()

while true do
    write("> ")
    local line = read()
    local cmd, a, b = line:match("^(%S+)%s*(%S*)%s*(%S*)$")

    if cmd == "quit" or cmd == "q" then
        break
    elseif cmd == "help" then
        showHelp()
    elseif cmd == "list" then
        showRelays()
    elseif cmd == "show" then
        showConfig()
    elseif cmd == "set" then
        local num = tonumber(b)
        if not config.relays[a] then
            print("Unknown position. Use: " .. table.concat(POSITIONS, ", "))
        elseif not num then
            print("Need a relay number. Run 'list' to see them.")
        else
            setRelay(a, num)
        end
    elseif cmd == "pulse" then
        if not config.relays[a] then
            print("Unknown position.")
        else
            pulse(a)
        end
    elseif cmd == "power" then
        local n = tonumber(a)
        if n then
            config.hoverPower = clamp(n, 0, 15); saveConfig(); print("Hover power: " .. config.hoverPower)
        else
            print("Need a number 0-15")
        end
    elseif cmd == "gain" then
        local n = tonumber(a)
        if n then
            config.kP = n; saveConfig(); print("kP: " .. config.kP)
        else
            print("Need a number")
        end
    elseif cmd == "side" then
        if a ~= "" then
            config.side = a; saveConfig(); print("Side: " .. a)
        else
            print("Need a side")
        end
    elseif cmd == "start" then
        stabilize()
    elseif cmd ~= "" then
        print("Unknown command. Type 'help'.")
    end
end
