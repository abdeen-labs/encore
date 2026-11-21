# The release DMG's window, for dmgbuild (https://dmgbuild.readthedocs.io). Scripts/publish-release.sh runs
#
#     dmgbuild -s Config/dmg-settings.py -D app=<path/to/Encore.app> -D background=<tiff> Encore <out.dmg>
#
# The background comes from Scripts/render-dmg-background.swift, which draws the arrow and the name capsules
# around the positions below: change both together.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "ULMO"  # LZMA
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")  # the volume's icon

# The window's content is the background's size, 660 × 400 points; icon positions are icon centers from the top
# left.
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (190, 262),
    "Applications": (470, 262),
}
