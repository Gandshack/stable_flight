-- stable_flight
-- flight stablizer program
local peripherals = {}
for index, name in ipairs(peripheral.getNames()) do
    table.insert(peripherals, { index = index, name = name })
end

for i, entry in ipairs(peripherals) do
    print(i, entry.name)
end
