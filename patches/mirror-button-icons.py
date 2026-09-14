#!/usr/bin/python3
"""Let a hyprbars button mirror its glyph horizontally.

macOS's green button shows two arrows on the NW-SE diagonal. Nerd Font's
arrow-expand runs the other way (NE-SW), and no installed font carries the
mirrored twin; Pango markup is unavailable, so it cannot be composed either.

Rather than settle for the wrong diagonal, this adds an optional `mirror`
field to add_button. When set, the glyph's texture is drawn with its U
coordinates swapped, which flips it horizontally and produces exactly the
missing icon.

Usage: mirror-button-icons.py <hyprbars source dir>
"""
import os
import sys

EDITS = [
    # 1. Carry the flag on the button.
    ("globals.hpp",
     """    std::string          icon    = "";
    SP<Render::ITexture> iconTex;""",
     """    std::string          icon    = "";
    bool                 mirror  = false;
    SP<Render::ITexture> iconTex;"""),

    # 2. Read it from the Lua table, defaulting to false so existing configs
    #    and other plugins' buttons are untouched.
    ("main.cpp",
     """        button.cmd = lua_tostring(L, -1);
    }

    g_pGlobalState->buttons.push_back(std::move(button));""",
     """        button.cmd = lua_tostring(L, -1);
    }

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

        lua_getfield(L, 1, "mirror");

        if (!lua_isnil(L, -1)) {
            if (!lua_isboolean(L, -1))
                return Config::Lua::Bindings::Internal::configError(L, "add_button: mirror must be a boolean");

            button.mirror = lua_toboolean(L, -1);
        }
    }

    g_pGlobalState->buttons.push_back(std::move(button));"""),

    # 3. Flip the texture by swapping its U coordinates.
    ("barDeco.cpp",
     """        if (!ICONONHOVER || (ICONONHOVER && m_iButtonHoverState > 0))
            g_pHyprOpenGL->renderTexture(button.iconTex, pos, {.a = a});""",
     """        if (!ICONONHOVER || (ICONONHOVER && m_iButtonHoverState > 0)) {
            if (button.mirror)
                g_pHyprOpenGL->renderTexture(button.iconTex, pos,
                                             {.a = a, .allowCustomUV = true, .primarySurfaceUVTopLeft = Vector2D(1, 0), .primarySurfaceUVBottomRight = Vector2D(0, 1)});
            else
                g_pHyprOpenGL->renderTexture(button.iconTex, pos, {.a = a});
        }"""),
]


def main():
    root = sys.argv[1]
    staged = []

    for filename, old, new in EDITS:
        path = os.path.join(root, filename)
        try:
            src = open(path).read()
        except OSError:
            print("  ERROR: %s is missing from the pinned checkout" % filename)
            return 1
        if new in src:
            continue                      # already applied
        if old not in src:
            # Pinned source: a mismatch means the tree is not what was
            # reviewed, so the build stops. See SOURCES.sha256.
            print("  ERROR: %s does not match the pinned commit" % filename)
            return 1
        staged.append((path, src.replace(old, new, 1)))

    # Only write once every edit is known to apply, so a partial patch can
    # never leave the tree in a state that fails to compile.
    for path, content in staged:
        open(path, "w").write(content)
    print("  added mirror support to button icons" if staged else "  already patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
