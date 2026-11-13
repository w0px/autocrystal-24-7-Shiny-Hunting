-- Originally written by M4_used_Rollout for Twitch Plays Pokemon

local bankSizes = {
    ROM = 0x4000,
    VRAM = 0x2000,
    SRAM = 0x2000,
    CartRAM = 0x2000, --a.k.a. SRAM
    WRAM = 0x1000
}

local knownRomBankAddresses = {
    Red = 0xFFB8,
    Blue = 0xFFB8,
    Yellow = 0xFFB8,
    Gold = 0xFF9F,
    Silver = 0xFF9F,
    Crystal = 0xFF9D,
    Pinball = 0xFFF8
}

local function LinearAddressToBank(linear, bankSize, noHomeBank)
    bankSize = bankSize or bankSizes.ROM
    local bank = math.floor(linear / bankSize)
    local address = linear % bankSize
    if bank > 0 and not noHomeBank then
        -- ROM and WRAM have a home bank (Bank 0)
        -- All switchable banks (Bank 1+) live after the home bank
        -- Add the bank size to the address to account for this
        address = address | bankSize
    end
    return address, bank
end

local function BankAddressToLinear(bank, address, bankSize)
    bankSize = bankSize or bankSizes.ROM
    return bank * bankSize | address % bankSize;
end

local function LinearAddressToBankString(linear, bankSize, noHomeBank)
    local address, bank = LinearAddressToBank(linear, bankSize, noHomeBank)
    return bizstring.hex(bank) .. ":" .. bizstring.hex(address)
end

local hROMBank = 0xFFFF -- use SetRomBankAddress to change this

local function CurrentROMBank()
    return memory.readbyte(hROMBank, "System Bus")
end

-- Hook groups (the speed check, 2026-11-11: with ~60 execute hooks always
-- registered, BizHawk's core ran ~262 fps where it runs ~2,600 with none -
-- every instruction is checked against the hooked addresses). A hook given
-- a group is only registered while its group is on: EnableHookGroup /
-- DisableHookGroup (counted - nested uses are fine), or WithHookGroup
-- around the code that needs it (the PC, the Mart, the bag...).
local defs = {}         -- name -> {fn, address, onRead, group, on}
local groups = {}       -- group -> {names = {...}, users = n}

local function hook_on(name)
    local d = defs[name]
    if not d or d.on then return end
    event.unregisterbyname(name)
    if d.onRead then event.onmemoryread(d.fn, d.address, name)
    else event.onmemoryexecute(d.fn, d.address, name) end
    d.on = true
end
local function hook_off(name)
    local d = defs[name]
    if not d or not d.on then return end
    event.unregisterbyname(name)
    d.on = false
end
local function group_of(g)
    local gr = groups[g]
    if not gr then gr = {names = {}, users = 0}; groups[g] = gr end
    return gr
end
local function EnableHookGroup(g)
    local gr = group_of(g)
    gr.users = gr.users + 1
    if gr.users == 1 then for _, name in ipairs(gr.names) do hook_on(name) end end
end
local function DisableHookGroup(g)
    local gr = group_of(g)
    gr.users = math.max(0, gr.users - 1)
    if gr.users == 0 then for _, name in ipairs(gr.names) do hook_off(name) end end
end
-- fn(...) with group g's hooks on - off again afterwards, errors too.
local function WithHookGroup(g, fn, ...)
    EnableHookGroup(g)
    local r = table.pack(pcall(fn, ...))
    DisableHookGroup(g)
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
end
-- How many hooks are registered now, and of how many known.
local function CountHooks()
    local on, all = 0, 0
    for _, d in pairs(defs) do all = all + 1; if d.on then on = on + 1 end end
    return on, all
end

local function RegisterROMHook(romAddr, action, name, onRead, group)
    if not romAddr then return end
    event.unregisterbyname(name)
    local address, bank = LinearAddressToBank(romAddr)
    -- (the speed check - modules/data/profiler.lua, on with profile_on.txt:
    -- each hook timed, and how often it was for the right bank)
    local P = AutocrystalProfiler
    if P then action = P.count_fire(name, action) end
    local execIfCorrectBank = function ()
        --print(name .. " Address " .. bizstring.hex(address) .. " Bank " .. bizstring.hex(bank) .. " Current Bank " .. CurrentROMBank() .. " hROMBank " .. bizstring.hex(hROMBank))
        if address < bankSizes.ROM or CurrentROMBank() == bank then
            --print(name)
            action()
        end
    end
    if P then execIfCorrectBank = P.wrap_hook(name, execIfCorrectBank) end
    defs[name] = {fn = execIfCorrectBank, address = address, onRead = onRead, group = group, on = false}
    if group then
        local gr = group_of(group)
        local known = false
        for _, n in ipairs(gr.names) do if n == name then known = true end end
        if not known then gr.names[#gr.names + 1] = name end
        if gr.users > 0 then hook_on(name) end
    else
        hook_on(name)
    end
    --print("Registered " .. name .. " on " .. bizstring.hex(romAddr) .. " (" .. bizstring.hex(bank) .. ":" .. bizstring.hex(address) .. ")")
end

local function SetRomBankAddress(addr)
    hROMBank = knownRomBankAddresses[addr] or addr
    if type(hROMBank) ~= "number" then
        print("Unknown ROM Bank addr")
    end
end

return {
    LinearAddressToBankString = LinearAddressToBankString,
    LinearAddressToBank = LinearAddressToBank,
    BankAddressToLinear = BankAddressToLinear,
    RegisterROMHook = RegisterROMHook,
    EnableHookGroup = EnableHookGroup,
    DisableHookGroup = DisableHookGroup,
    WithHookGroup = WithHookGroup,
    CountHooks = CountHooks,
    RegisterDirectROMHook = RegisterDirectROMHook,
    CurrentROMBank = CurrentROMBank,
    SetRomBankAddress = SetRomBankAddress,
    BankSizes = bankSizes
}