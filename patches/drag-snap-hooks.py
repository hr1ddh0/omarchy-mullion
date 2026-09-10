#!/usr/bin/env python3
"""Drive drag-to-edge snapping from hyprbars' own title-bar drags.

hyprbars listens to pointer events itself and moves the window when you drag
its title bar, so a Hyprland mouse binding never sees that drag -- only
SUPER+drag reaches one. Dragging a window by its title bar, which is what
anyone actually does, therefore produced no snap preview at all.

This calls macos-drag-snap at the two points hyprbars already knows about:
handleMovement() when a title-bar drag begins, and handleUpEvent() when one
ends. It reuses the same "exec" dispatcher hyprbars uses for button actions.

Usage: drag-snap-hooks.py <hyprbars source dir>
"""
import os
import sys

SNAP = '$HOME/.local/bin/macos-drag-snap'

EDITS = [
    # Drag begins.
    ("barDeco.cpp",
     """void CHyprBar::handleMovement() {
    g_pKeybindManager->changeMouseBindMode(MBIND_MOVE);
    m_bDraggingThis = true;""",
     """void CHyprBar::handleMovement() {
    g_pKeybindManager->changeMouseBindMode(MBIND_MOVE);
    m_bDraggingThis = true;
    // Start the drag-to-edge snap preview.
    g_pKeybindManager->m_dispatchers["exec"]("%s start");""" % SNAP),

    # Drag ends.
    ("barDeco.cpp",
     """    if (m_bDraggingThis) {
        g_pKeybindManager->changeMouseBindMode(MBIND_INVALID);
        m_bDraggingThis = false;""",
     """    if (m_bDraggingThis) {
        g_pKeybindManager->changeMouseBindMode(MBIND_INVALID);
        m_bDraggingThis = false;
        // Finish the drag: hide the preview and snap if we ended on an edge.
        g_pKeybindManager->m_dispatchers["exec"]("%s end");""" % SNAP),
]


def main():
    root = sys.argv[1]
    path = os.path.join(root, "barDeco.cpp")
    try:
        src = open(path).read()
    except OSError:
        print("  barDeco.cpp missing; skipping the drag-hook patch")
        return 0

    if all(new in src for _, _, new in EDITS):
        print("  already patched")
        return 0

    for _, old, new in EDITS:
        if new in src:
            continue
        if old not in src:
            print("  upstream drag handling changed; skipping the drag-hook patch")
            return 0
        src = src.replace(old, new, 1)

    open(path, "w").write(src)
    print("  hooked title-bar drags into drag-snap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
