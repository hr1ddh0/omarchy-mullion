#!/usr/bin/python3
"""Centre hyprbars' button glyphs on their dots.

hyprbars draws the coloured circle into a box it rounds to whole pixels, but
positions the glyph from the same unrounded arithmetic without rounding. At a
macOS-sized 12px dot the glyph lands about a pixel left of centre, which is
plainly visible.

This centres the glyph inside the very same rounded box the circle is drawn
into, so the two cannot disagree, and floors the result so that any half-pixel
residue falls the same way for every glyph rather than varying per icon.

Usage: center-button-icons.py <hyprbars source dir>
"""
import os
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
        // Floor rather than round. A glyph whose texture is an odd number of
        // pixels wide cannot sit dead centre in an even-width dot, so half a
        // pixel has to go somewhere; rounding sent it left for some glyphs and
        // right for others, and a row of marks each off a different way is what
        // actually reads as misaligned. Flooring puts every glyph's residue on
        // the same side, so the row lines up with itself.
        const auto iconX = std::floor(iconButtonBox.x + (iconButtonBox.w - button.iconTex->m_size.x) / 2.0);
        const auto iconY = std::floor(iconButtonBox.y + (iconButtonBox.h - button.iconTex->m_size.y) / 2.0);
        CBox       pos   = {iconX, iconY, button.iconTex->m_size.x, button.iconTex->m_size.y};"""


def main():
    path = os.path.join(sys.argv[1], "barDeco.cpp")
    src = open(path).read()
    if NEW.split("\n")[-1] in src and "iconButtonBox" in src:
        print("  already patched")
        return 0
    if OLD not in src:
        # The source is pinned to an exact commit, so this text is either
        # present or the tree is not what this release was built against.
        # Skipping used to be the lenient choice; with a pin it would mean
        # compiling something nobody reviewed, so it fails the build instead.
        print("  ERROR: barDeco.cpp does not match the pinned commit")
        return 1
    open(path, "w").write(src.replace(OLD, NEW, 1))
    print("  centred button glyphs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
