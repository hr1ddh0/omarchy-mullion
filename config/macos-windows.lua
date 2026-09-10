-- macOS-style window handling.
--
--   1. Title bars with red/yellow/green traffic lights. Drag a bar to move the
--      window, double-click it to zoom.
--   2. Drag any window edge or corner to resize -- no modifier key needed.
--   3. Windows float freely instead of being auto-tiled.
--
-- The title bar comes from the hyprbars plugin, loaded in hyprland.lua. Its
-- colors live in ~/.config/omarchy/themed/hyprland.lua.tpl so they follow
-- whichever Omarchy theme is active.
--
-- To turn all of this off: delete the require("hypr.macos-windows") line and
-- the hl.plugin.load(...) block in ~/.config/hypr/hyprland.lua.
--
-- NOTE ON ACTIONS: Omarchy configures Hyprland in Lua, so `hyprctl dispatch`
-- takes a Lua expression, not the old `hyprctl dispatch fullscreen 1` form.
-- The old form fails silently -- the button would look fine and do nothing.

-- ---------------------------------------------------------------------------
-- Resize by dragging edges and corners, the way every Mac window works.
hl.config({
  general = {
    -- Grab a border to resize, instead of needing SUPER + right-drag.
    resize_on_border = true,
    -- Widen the invisible grab zone so you don't have to hit 3px exactly.
    extend_border_grab_area = 15,
    -- Show the resize cursor when hovering an edge.
    hover_icon_on_border = true,
  },
})

-- ---------------------------------------------------------------------------
-- Every window opens floating and stays where you put it, like macOS, instead
-- of being auto-arranged into a tiling grid. New windows are centered.
--
-- SUPER + T tiles the focused window if you want tiling back for one window.
o.window(".*", { float = true })

-- Remember each window's size between launches rather than resetting it.
o.window(".*", { persistent_size = true })

-- ---------------------------------------------------------------------------
-- Title bars.
--
-- A plugin's Lua API only becomes visible on the config parse AFTER the one
-- that loaded it, so on a cold start this block is skipped and we re-read the
-- config once to pick it up. Every later parse takes the fast path.
if hl.plugin.hyprbars then
  hl.config({
    plugin = {
      hyprbars = {
        bar_height = 30,
        bar_padding = 12,
        bar_button_padding = 9,
        bar_text_size = 11,
        bar_text_font = "JetBrainsMono Nerd Font",
        bar_text_align = "center",
        -- Traffic lights on the left, like macOS.
        bar_buttons_alignment = "left",
        -- Glyphs appear inside the dots only on hover, like macOS.
        icon_on_hover = true,
        -- The bar reserves its own space rather than covering the window.
        bar_part_of_window = true,
        bar_precedence_over_border = true,
        -- Double-click the bar to zoom/unzoom.
        on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
      },
    },
  })

  -- Buttons render left-to-right in the order they are added.

  -- Close.
  hl.plugin.hyprbars.add_button({
    bg_color = "rgb(ff5f57)",
    fg_color = "rgba(000000aa)",
    size = 12,
    icon = "✕",
    action = [[hyprctl dispatch 'hl.dsp.window.close()']],
  })

  -- Minimize. Hyprland has no minimize, so this parks the window on the
  -- window-shelf workspace. The shelf widget in the left of the top bar then
  -- shows it as a clickable chip -- click the chip to bring it back.
  hl.plugin.hyprbars.add_button({
    bg_color = "rgb(febc2e)",
    fg_color = "rgba(000000aa)",
    size = 12,
    icon = "−",
    action = [[hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false })']],
  })

  -- Zoom: fills the screen below the bar, and restores to the exact previous
  -- size and position on a second click, like the macOS green button.
  hl.plugin.hyprbars.add_button({
    bg_color = "rgb(28c840)",
    fg_color = "rgba(000000aa)",
    size = 12,
    icon = "+",
    action = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
  })
else
  -- Cold start: the plugin loaded during this very parse, so re-read the
  -- config once at launch to pick up its Lua API and draw the buttons.
  o.exec_on_start("hyprctl reload")
end

-- ---------------------------------------------------------------------------
-- Mac muscle memory. SUPER stands in for Command.
-- Minimized windows land on the shelf and appear as chips in the top-left of
-- the bar, so they are always visible and one click from being restored.
o.bind("SUPER + M", "Minimize window (to shelf)", hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false }))
