-- Add this near the TOP of ~/.config/hypr/hyprland.lua, BEFORE the
-- require("default.hypr.omarchy") line, so the active theme can color the bar.
--
-- pcall-guarded: a plugin built against a different Hyprland version simply
-- doesn't load, and the desktop still starts normally without title bars.
pcall(function()
  hl.plugin.load(os.getenv("HOME") .. "/.local/share/hyprland/plugins/hyprbars.so")
end)

-- ...and add this AFTER require("hypr.looknfeel"):
-- require("hypr.macos-windows")
