-- family.lua (lives in modules/data/)
-- One ID for one Pokemon that survives evolving: the first form of its
-- evolution family + DVs + trainer ID ("10:9876:4660" stays the same when
-- that Caterpie becomes Metapod). The user's log, 2026-11-08: a Caterpie
-- being trained reached Lv 8 mid-training, evolved, and - recognised by
-- species - counted as gone, so its training was "done" at Lv 7.
--
-- M.setup(battleData.evos) by play; until then the species itself (tests).

local M = {}

local prev = nil    -- species -> what it evolves from

function M.setup(evos)
    prev = {}
    for from, list in pairs(evos or {}) do
        for _, e in ipairs(list) do
            local to = e[#e]
            if type(to) == "number" and not prev[to] then prev[to] = from end
        end
    end
end

-- The first form of species' family (Pichu for Raichu, Tyrogue for Hitmontop).
function M.base(sp)
    if not prev then return sp end
    local seen = {}
    while prev[sp] and not seen[sp] do seen[sp] = true; sp = prev[sp] end
    return sp
end

-- The ID: base:DVs:OT.
function M.fp(species, dv1, dv2, otId)
    return string.format("%d:%02X%02X:%d", M.base(species), dv1, dv2, otId)
end

return M
