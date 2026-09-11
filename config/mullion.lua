-- macOS-style window handling.
--
--   1. Title bars with red/yellow/green traffic lights. Drag a bar to move the
--      window, double-click it to zoom.
--   2. Drag any window edge or corner to resize, no modifier key needed.
--   3. Windows float freely instead of being auto-tiled.
--
-- The title bar comes from the hyprbars plugin, loaded in hyprland.lua. Its
-- colors live in ~/.config/omarchy/themed/hyprland.lua.tpl so they follow
-- whichever Omarchy theme is active.
--
-- To turn all of this off: delete the require("hypr.mullion") line and
-- the hl.plugin.load(...) block in ~/.config/hypr/hyprland.lua.
--
-- NOTE ON ACTIONS: Omarchy configures Hyprland in Lua, so `hyprctl dispatch`
-- takes a Lua expression, not the old `hyprctl dispatch fullscreen 1` form.
-- The old form fails silently: the button would look fine and do nothing.

-- ---------------------------------------------------------------------------
-- Settings.
--
-- Everything tweakable lives in ~/.config/omarchy/mullion.conf, written by
-- the settings panel in the bar and equally editable by hand. Plain key=value
-- so the Hyprland config, the drag-snap helper and the panel can all read the
-- same file. Missing keys fall back to the defaults below, so a partial or
-- absent file is always safe.
-- Each tunable declares its type and, for numbers, the range it is allowed to
-- take. A value that is missing, misspelled, the wrong type or out of range
-- falls back to the default rather than reaching Hyprland: a typo in this file
-- should never be able to produce a desktop with no borders, a negative title
-- bar, or square corners you did not ask for.
local schema = {
  window_style = { default = "macos", choices = { macos = true, windows = true, none = true } },
  button_size = { default = 12, min = 6, max = 28 },
  bar_height = { default = 28, min = 16, max = 64 },
  icons_always_visible = { default = true },
  rounding = { default = 10, min = 0, max = 32 },
  border_size = { default = 3, min = 0, max = 12 },
  gaps_in = { default = 6, min = 0, max = 40 },
  gaps_out = { default = 12, min = 0, max = 80 },
  float_by_default = { default = true },
  shadow = { default = true },
  drag_snap = { default = true },
}

local settings = {}
for key, rule in pairs(schema) do
  settings[key] = rule.default
end

do
  local path = os.getenv("HOME") .. "/.config/omarchy/mullion.conf"
  local file = io.open(path, "r")
  if file then
    for line in file:lines() do
      if not line:match("^%s*#") then
        local key, raw = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        local rule = key and schema[key]
        if rule then
          if type(rule.default) == "boolean" then
            -- Only the two literals count; anything else keeps the default.
            if raw == "true" or raw == "false" then
              settings[key] = raw == "true"
            end
          elseif type(rule.default) == "number" then
            local value = tonumber(raw)
            if value then
              -- Clamp rather than reject, so a value that is merely too large
              -- still does something sensible.
              if rule.min and value < rule.min then value = rule.min end
              if rule.max and value > rule.max then value = rule.max end
              settings[key] = math.floor(value)
            end
          elseif rule.choices then
            if rule.choices[raw] then settings[key] = raw end
          end
        end
      end
    end
    file:close()
  end
end

-- ---------------------------------------------------------------------------
-- Window style.
--
-- The two platforms differ in where the buttons sit, what they look like, how
-- the title is aligned and how the window is lifted off the desktop. Snapping
-- and edge-resize are identical in both, so they live outside this.
local style = settings.window_style

-- Colours from the active theme, handed over by
-- ~/.config/omarchy/themed/hyprland.lua.tpl earlier in this same parse.
local theme = _G.mullion_theme or {}
local theme_foreground = theme.foreground or "#ffffff"

-- macOS lifts a window with a large, very soft shadow. Windows 11 sits closer
-- to the desktop: a tighter shadow with far less offset.
local elevation = {
  macos = { range = 32, offset = "0 10", alpha = "73", inactive = "38" },
  windows = { range = 18, offset = "0 4", alpha = "66", inactive = "30" },
  none = { range = 18, offset = "0 4", alpha = "66", inactive = "30" },
}
local lift = elevation[style]

hl.config({
  decoration = {
    shadow = {
      enabled = settings.shadow,
      render_power = 3,
      range = lift.range,
      offset = lift.offset,
      -- Neutral rather than accent-tinted: a coloured shadow at this size
      -- reads as a smear, and the border is what carries the accent.
      color = "rgba(000000" .. lift.alpha .. ")",
      color_inactive = "rgba(000000" .. lift.inactive .. ")",
    },
  },
})

-- ---------------------------------------------------------------------------
-- Window shape.
--
-- Rounded corners, and a border wide enough that the theme's accent gradient
-- actually reads as a gradient rather than a hairline. The drop shadow that
-- pairs with this lives in ~/.config/omarchy/themed/hyprland.lua.tpl, because
-- it has to be re-emitted whenever the theme changes.
--
-- This loads after hypr/looknfeel.lua and so wins over it. If you would rather
-- set these yourself, delete this block and they fall back to whatever your
-- looknfeel.lua says.
hl.config({
  general = {
    border_size = settings.border_size,
    gaps_in = settings.gaps_in,
    gaps_out = settings.gaps_out,
  },

  decoration = {
    rounding = settings.rounding,
  },
})

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
if settings.float_by_default then
  o.window(".*", { float = true })
end

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
        bar_height = settings.bar_height,
        bar_padding = 12,
        bar_button_padding = 8,
        bar_text_size = 11,
        bar_text_font = "JetBrainsMono Nerd Font",
        -- Windows-style buttons have no plate, so the greying that unfocused
        -- traffic lights want would draw three circles that should not exist.
        inactive_button_color = style == "windows" and "rgba(00000000)"
          or (_G.mullion_theme and _G.mullion_theme.muted) or "rgba(00000000)",
        bar_text_align = style == "windows" and "left" or "center",
        -- macOS puts its lights on the left; Windows its caption buttons on
        -- the right.
        bar_buttons_alignment = style == "windows" and "right" or "left",
        -- Keep the glyphs visible rather than hover-only: at this size they
        -- read as crisp marks, and always-on is easier to hit accurately.
        -- Set this back to true for strict macOS hover behavior.
        icon_on_hover = not settings.icons_always_visible,
        -- The bar reserves its own space rather than covering the window.
        bar_part_of_window = true,
        bar_precedence_over_border = true,
        -- Double-click the bar to zoom/unzoom.
        on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
      },
    },
  })

  -- Buttons render in the order they are added: left-to-right when they sit on
  -- the left, right-to-left when they sit on the right, so each style lists
  -- them in the order that platform shows them.
  --
  -- macOS draws filled circles carrying the mark. Windows 11 draws no plate at
  -- rest at all: just the glyph on the bar, with the backplate appearing on
  -- hover, so its buttons use a fully transparent background and take their
  -- colour from the theme's foreground.
  if style == "macos" then
    hl.plugin.hyprbars.add_button({
      bg_color = "rgb(ff5f57)",
      fg_color = "rgb(000000)",
      size = settings.button_size,
      icon = "",
      action = [[hyprctl dispatch 'hl.dsp.window.close()']],
    })

    hl.plugin.hyprbars.add_button({
      bg_color = "rgb(febc2e)",
      fg_color = "rgb(000000)",
      size = settings.button_size,
      icon = "",
      action = [[hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false })']],
    })

    hl.plugin.hyprbars.add_button({
      bg_color = "rgb(28c840)",
      fg_color = "rgb(000000)",
      size = settings.button_size,
      icon = "󰘖",
      mirror = true,
      action = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
    })
  elseif style == "windows" then
    -- Minimise, maximise, close: reading left to right on screen, which is
    -- the reverse of the order they are added when right-aligned.
    hl.plugin.hyprbars.add_button({
      bg_color = "rgba(00000000)",
      fg_color = theme_foreground,
      size = settings.button_size,
      icon = "",
      action = [[hyprctl dispatch 'hl.dsp.window.close()']],
    })

    hl.plugin.hyprbars.add_button({
      bg_color = "rgba(00000000)",
      fg_color = theme_foreground,
      size = settings.button_size,
      -- A plain square outline, which is what Windows 11 draws. The icon-font
      -- "window maximise" glyphs all carry a filled title-bar strip and read
      -- as a different mark at this size.
      icon = "□",
      action = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
    })

    hl.plugin.hyprbars.add_button({
      bg_color = "rgba(00000000)",
      fg_color = theme_foreground,
      size = settings.button_size,
      icon = "",
      action = [[hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false })']],
    })
  end
  -- style == "none": a bar to drag and a title, and nothing to click.

else
  -- The plugin loaded during this very parse, so its Lua API only becomes
  -- visible on the next one. Re-read the config once to pick it up.
  --
  -- o.exec_on_start fires only at login, which would leave a live
  -- `hyprctl reload` with default-styled bars and no buttons, so trigger the
  -- re-read directly. The marker file rate-limits it to once every 10s, so a
  -- plugin that never exposes its API cannot spin us in a reload loop.
  local marker = "/tmp/mullion-reload-" .. (os.getenv("USER") or "user")
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
-- These four were Omarchy's directional window focus, a tiling-first idea
-- that this floating-first setup does not need, so they are given over to
-- snapping entirely. Focus follows the mouse and clicks, as on macOS.
hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + UP")
hl.unbind("SUPER + DOWN")

o.bind("SUPER + LEFT", "Snap window left / quarter", "mullion-snap left")
o.bind("SUPER + RIGHT", "Snap window right / quarter", "mullion-snap right")
o.bind("SUPER + UP", "Snap window up / quarter", "mullion-snap top")
o.bind("SUPER + DOWN", "Snap window down / quarter", "mullion-snap bottom")

-- Arrows compose, exactly like Windows Snap: LEFT then UP puts the window in
-- the top-left quarter, so four apps tile a workspace with two presses each.
-- That is the whole split-screen surface; no second set of keys for it.
--
-- `mullion-snap full` and `center` still exist as commands if you ever want to
-- bind them, but full screen is already SUPER+F and the green title-bar
-- button, so they are deliberately left unbound.

-- ---------------------------------------------------------------------------
-- Drag a window to a screen edge to snap it there, with a live preview of
-- where it will land. Windows calls this Aero Snap.
--
--   edges   -> half screen (top edge fills the screen)
--   corners -> quarter screen, so four windows tile one workspace
--
-- Hyprland has no drag events, so the press and release of the same
-- SUPER + left-drag that moves a window mark the start and end of one. Both
-- binds are non-consuming, so Omarchy's own "Move window" binding still runs
-- and the drag itself behaves exactly as before; if this is removed, nothing
-- about dragging changes.
o.bind("SUPER + mouse:272", "Begin drag-snap", "mullion-drag-snap start", { non_consuming = true })
o.bind("SUPER + mouse:272", "Finish drag-snap", "mullion-drag-snap end", { non_consuming = true, release = true })

-- ---------------------------------------------------------------------------
-- Mac muscle memory. SUPER stands in for Command.
-- Minimized windows land on the shelf and appear as chips in the top-left of
-- the bar, so they are always visible and one click from being restored.
o.bind("SUPER + M", "Minimize window (to shelf)", hl.dsp.window.move({ workspace = "special:omarchy-minimized", follow = false }))
