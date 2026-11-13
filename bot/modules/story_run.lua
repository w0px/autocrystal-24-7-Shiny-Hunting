-- story_run.lua - plays the story on its own, without the launcher: the
-- same bot (modules/play.lua) with the settings saved by the launcher (or
-- the defaults). The launcher (launcher.lua, one folder up) is the usual
-- way now - it has the settings and a Stop button.
--
-- Crystal (English). New game: do the intro yourself (name, gender, the
-- clock) until you stand in your room - or load any save on the way. Then
-- Lua Console > Open Script > this file.

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path
package.loaded["play"] = nil

local Play = require("play")
local okStore, store = pcall(require, "data.gui_settings")
local settings = Play.defaults()
if okStore and store then
    pcall(store.load)
    settings = Play.load_settings(store)
end
Play.run(script_dir, settings, {})
