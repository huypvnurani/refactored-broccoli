# dmgbuild settings for the MacCharge installer window, used by make_dmg.sh:
#   dmgbuild -s dmg_settings.py -D staging=<dir> -D background=<tiff> MacCharge <out.dmg>
# Positions are icon centres in window points and must match
# make_dmg_background.py (WIDTH, HEIGHT, APP_X, APPS_X, ICON_Y, NOTE_Y).
import os

staging = defines["staging"]  # noqa: F821 — provided by dmgbuild
note = "README - How to open.txt"

format = "UDZO"
files = [os.path.join(staging, "MacCharge.app")]
if os.path.exists(os.path.join(staging, note)):
    files.append(os.path.join(staging, note))
symlinks = {"Applications": "/Applications"}

background = defines["background"]  # noqa: F821
window_rect = ((200, 140), (660, 480))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    "MacCharge.app": (170, 205),
    "Applications": (490, 205),
    note: (330, 390),
}
