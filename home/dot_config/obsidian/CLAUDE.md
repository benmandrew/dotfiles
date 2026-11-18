# Obsidian

Paths are relative to the chezmoi source root.

`home/dot_config/obsidian/modify_obsidian.json` pins `"frame": "native"`, since Electron rounds a frameless window unless the compositor marks it tiled, and Pop Shell never does. The native frame takes its square corners from `gtk-3.0/gtk.css`.

Each rule says what to preserve; the commit that introduced it records why.
