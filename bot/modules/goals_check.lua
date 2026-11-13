-- goals_check.lua - shows the current section's goals (a living dex,
-- data/goals.lua): what's still to catch shiny, what to evolve, what you
-- have. Reads only - presses nothing. The launcher's "Show goals" button
-- does the same. Uses the launcher's saved settings (the testing switch).
--
-- Crystal (English). Lua Console > Open Script > this file, anywhere.

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path
package.loaded["play"] = nil
local Play = require("play")
local okStore, store = pcall(require, "data.gui_settings")
local settings = Play.defaults()
if okStore and store then pcall(store.load); settings = Play.load_settings(store) end
Play.show_goals(script_dir, settings, print)
