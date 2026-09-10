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

    -- Magnetic snapping: a dragged window sticks to screen edges and to other
    -- windows when it gets close, so windows line up without pixel-hunting.
    snap = {
      enabled = true,
      window_gap = 10,
      monitor_gap = 10,
    },
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
        bar_height = 28,
        bar_padding = 12,
        bar_button_padding = 8,
        bar_text_size = 11,
        bar_text_font = "JetBrainsMono Nerd Font",
        bar_text_align = "center",
        -- Traffic lights on the left, like macOS.
        bar_buttons_alignment = "left",
        -- Keep the glyphs visible rather than hover-only: at this size they
        -- read as crisp marks, and always-on is easier to hit accurately.
        -- Set this back to true for strict macOS hover behavior.
        icon_on_hover = false,
        -- The bar reserves its own space rather than covering the window.
        bar_part_of_window = true,
        bar_precedence_over_border = true,
        -- Double-click the bar to zoom/unzoom.
        on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
      },
    },
  })

  -- Buttons render left-to-right in the order they are added.
  --
  -- The glyphs are Nerd Font icons rather than the plain Unicode ✕ − + marks.
  -- hyprbars draws the icon at size*0.62, so a macOS-sized 12px dot leaves
  -- only 7px, and at 7px the thin Unicode strokes turn to mush. Nerd Font
  -- icons are drawn to fill their cell, so they stay legible at that size.
  -- hyprbars asks for "sans"; Pango falls back to an icon font for these
  -- codepoints on its own.

  -- Close.
  hl.plugin.hyprbars.add_button({
    bg_color = "rgb(ff5f57)",
    fg_color = "rgb(000000)",
    size = 12,
    icon = "",
    action = [[hyprctl dispatch 'hl.dsp.window.close()']],
  })

  -- Minimize. Hyprland has no minimize, so this parks the window on the
  -- window-shelf workspace. The shelf widget in the left of the top bar then
  -- shows it as a clickable chip -- click the chip to bring it back.
  hl.plugin.hyprbars.add_button({
    bg_color = "rgb(febc2e)",
    fg_color = "rgb(000000)",
    size = 12,
    icon = "",
    action = [[hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false })']],
  })

  -- Zoom: fills the screen below the bar, and restores to the exact previous
  -- size and position on a second click, like the macOS green button.
  --
  -- The glyph is the pair of outward diagonal arrows macOS has shown here
  -- since Yosemite; the older "+" now only appears on dialogs that cannot go
  -- full screen. Chosen by rendering every plausible codepoint as a live
  -- button and comparing them: several fullscreen glyphs draw as empty circles
  -- through hyprbars' hardcoded "sans" family, and a two-glyph pair overflows
  -- the dot. This one reads correctly at the size hyprbars allows.
  hl.plugin.hyprbars.add_button({
    bg_color = "rgb(28c840)",
    fg_color = "rgb(000000)",
    size = 12,
    icon = "󰘖",
    -- The font's arrows run NE-SW; macOS runs them NW-SE and no installed
    -- font carries the mirrored twin, so the build patch flips the glyph.
    mirror = true,
    action = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
  })
else
  -- The plugin loaded during this very parse, so its Lua API only becomes
  -- visible on the next one. Re-read the config once to pick it up.
  --
  -- o.exec_on_start fires only at login, which would leave a live
  -- `hyprctl reload` with default-styled bars and no buttons, so trigger the
  -- re-read directly. The marker file rate-limits it to once every 10s, so a
  -- plugin that never exposes its API cannot spin us in a reload loop.
  local marker = "/tmp/cupertino-reload-" .. (os.getenv("USER") or "user")
  hl.exec_cmd("sh -c 'now=$(date +%s); last=$(cat " .. marker .. " 2>/dev/null || echo 0); "
    .. "if [ $((now - last)) -ge 10 ]; then echo $now > " .. marker
    .. "; sleep 1; hyprctl reload; fi'")
end

-- ---------------------------------------------------------------------------
-- Split screen. Snap the focused window to half the screen, the way macOS
-- tiling and Windows Snap do. The helper reads the real monitor geometry and
-- the bar's reserved area, so it is correct on any display.
--
-- SUPER + [ and SUPER + ] were free; every SUPER+arrow combination is already
-- taken by Omarchy (focus, swap, and window groups).
-- SUPER + arrows, the same keys Windows uses, so there is nothing to learn.
--
-- These four were Omarchy's directional window focus -- a tiling-first idea
-- that this floating-first setup does not need, so they are given over to
-- snapping entirely. Focus follows the mouse and clicks, as on macOS.
hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + UP")
hl.unbind("SUPER + DOWN")

o.bind("SUPER + LEFT", "Snap window left / quarter", "macos-snap left")
o.bind("SUPER + RIGHT", "Snap window right / quarter", "macos-snap right")
o.bind("SUPER + UP", "Snap window up / quarter", "macos-snap top")
o.bind("SUPER + DOWN", "Snap window down / quarter", "macos-snap bottom")

-- Arrows compose, exactly like Windows Snap: LEFT then UP puts the window in
-- the top-left quarter, so four apps tile a workspace with two presses each.
-- That is the whole split-screen surface -- no second set of keys for it.
--
-- `macos-snap full` and `center` still exist as commands if you ever want to
-- bind them, but full screen is already SUPER+F and the green title-bar
-- button, so they are deliberately left unbound.

-- ---------------------------------------------------------------------------
-- Drag a window to a screen edge to snap it there, with a live preview of
-- where it will land -- the behavior Windows calls Aero Snap.
--
--   edges   -> half screen (top edge fills the screen)
--   corners -> quarter screen, so four windows tile one workspace
--
-- Hyprland has no drag events, so the press and release of the same
-- SUPER + left-drag that moves a window mark the start and end of one. Both
-- binds are non-consuming, so Omarchy's own "Move window" binding still runs
-- and the drag itself behaves exactly as before -- if this is removed, nothing
-- about dragging changes.
o.bind("SUPER + mouse:272", "Begin drag-snap", "macos-drag-snap start", { non_consuming = true })
o.bind("SUPER + mouse:272", "Finish drag-snap", "macos-drag-snap end", { non_consuming = true, release = true })

-- ---------------------------------------------------------------------------
-- Mac muscle memory. SUPER stands in for Command.
-- Minimized windows land on the shelf and appear as chips in the top-left of
-- the bar, so they are always visible and one click from being restored.
o.bind("SUPER + M", "Minimize window (to shelf)", hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false }))
