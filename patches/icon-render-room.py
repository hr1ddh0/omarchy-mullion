#!/usr/bin/env python3
"""Give hyprbars' button glyphs room to render.

Two upstream choices make the marks hard to read at a macOS-sized 12px dot:

  * the glyph is drawn at size * 0.62, which leaves 7px -- small enough that
    thin strokes disappear;
  * the text is laid out with maxWidth = the button size, so any icon wider
    than the dot (a two-glyph mark, for instance) is truncated to an ellipsis.

This nudges the scale up slightly and lets the layout use the room it needs.
Both are cosmetic, so a mismatch is skipped rather than failing the build.

Usage: icon-render-room.py <hyprbars source dir>
"""
import os
import sys

OLD = ('button.iconTex = g_pHyprRenderer->renderText(button.icon, fgcol, '
       'std::round(button.size * 0.62 * scale), false, "sans", scaledButtonSize);')
NEW = ('button.iconTex = g_pHyprRenderer->renderText(button.icon, fgcol, '
       'std::round(button.size * 0.72 * scale), false, "sans", scaledButtonSize * 3);')


def main():
    path = os.path.join(sys.argv[1], "barDeco.cpp")
    src = open(path).read()
    if NEW in src:
        print("  already patched")
        return 0
    if OLD not in src:
        print("  upstream icon rendering changed; skipping the render-room patch")
        return 0
    open(path, "w").write(src.replace(OLD, NEW, 1))
    print("  gave button glyphs render room (0.62 -> 0.72, wider layout)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
