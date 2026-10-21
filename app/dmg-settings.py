# SPDX-License-Identifier: GPL-2.0-or-later
# dmgbuild settings for the installer disk image (see app/make-dmg.sh).
# Pass -D app=… -D background=… -D icon=…; the background's @2x twin is picked up too.
import os

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
name = os.path.basename(application)

files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821 — the volume's icon
background = defines["background"]  # noqa: F821

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

# 640×400 artwork; the window's bounds include its title bar
window_rect = ((240, 160), (640, 422))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 128
# the icon spots of DMGBackground (app/Snapshot/Snapshot.swift)
icon_locations = {name: (165, 200), "Applications": (475, 200)}
