# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Diego Zamarron
# Layout of the installer window, read by dmgbuild (see Tools/make_dmg.sh).
# Defines passed in: app (path to FallingNotes.app), background (.tiff), icon (volume icon .icns).
import os

app_path = defines["app"]
app_name = os.path.basename(app_path)

format = "UDZO"
filesystem = "HFS+"

files = [app_path]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]                  # the icon shown for the mounted disk
background = defines["background"]

# The window is exactly the size of the background art (660 x 400 points).
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 12
arrange_by = None

# Icon centres, matching the arrow drawn in the background.
icon_locations = {
    app_name: (170, 160),
    "Applications": (490, 160),
}
