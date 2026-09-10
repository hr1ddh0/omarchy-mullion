#!/usr/bin/env python3
"""Centre hyprbars' button glyphs on their dots.

hyprbars draws the coloured circle into a box it rounds to whole pixels, but
positions the glyph from the same unrounded arithmetic without rounding. At a
macOS-sized 12px dot the glyph lands about a pixel left of centre, which is
plainly visible.

This centres the glyph inside the very same rounded box the circle is drawn
into, so the two cannot disagree.

Usage: center-button-icons.py <path to hyprbars/barDeco.cpp>
"""
import sys

OLD = """        const auto iconX = barBox->x + (BUTTONSRIGHT ? barBox->width - offset - scaledButtonSize / 2.0 : offset + scaledButtonSize / 2.0) - button.iconTex->m_size.x / 2.0;
        const auto iconY = barBox->y + barBox->height / 2.0 - button.iconTex->m_size.y / 2.0;
        CBox       pos   = {iconX, iconY, button.iconTex->m_size.x, button.iconTex->m_size.y};"""

NEW = """        // Centre the glyph inside the same rounded box renderBarButtons draws
        // the circle into, instead of re-deriving an unrounded position, so the
        // glyph cannot sit a pixel off the dot.
        CBox iconButtonBox = {barBox->x + (BUTTONSRIGHT ? barBox->w - offset - scaledButtonSize : offset), barBox->y + (barBox->h - scaledButtonSize) / 2.0, scaledButtonSize,
                              scaledButtonSize};
        iconButtonBox.round();
        const auto iconX = std::round(iconButtonBox.x + (iconButtonBox.w - button.iconTex->m_size.x) / 2.0);
        const auto iconY = std::round(iconButtonBox.y + (iconButtonBox.h - button.iconTex->m_size.y) / 2.0);
        CBox       pos   = {iconX, iconY, button.iconTex->m_size.x, button.iconTex->m_size.y};"""


def main():
    path = sys.argv[1]
    src = open(path).read()
    if NEW.split("\n")[-1] in src and "iconButtonBox" in src:
        print("  already patched")
        return 0
    if OLD not in src:
        print("  upstream code changed; skipping the icon-centring patch")
        return 0        # never fail the build over a cosmetic patch
    open(path, "w").write(src.replace(OLD, NEW, 1))
    print("  centred button glyphs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
