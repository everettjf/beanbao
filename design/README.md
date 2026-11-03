# BeanBao app icon

The 1254 px `beanbao-icon-master.png` was edited with the built-in image
generation tool on 2026-11-03. It keeps the smiling steamed-bun mascot and
three coral sound-wave arcs, with a warm terracotta-to-apricot background.
`beanbao-icon-1024.png` is the distribution master. Run
`scripts/render_icon_sizes.sh` after changing the master to regenerate the
website image and all icon sizes in `app/Resources/`. The icon has no text or rounded-corner mask.

`beanbao-helper-icon-master.png` is the 1254 px distinct Helper icon, also
generated from the BeanBao mascot reference on 2026-11-03. Its coral sparkle
badge and lighter honey background distinguish the two installed apps at small
Home Screen sizes. `beanbao-helper-icon-1024.png` is its distribution master;
the same script generates `delivery-browser/Resources/` icons from it.

`architecture.svg` is the warm vector diagram used by both README languages.
It shows the two visible apps, on-device Agent and Bridge, their distinct IPC
paths, and the optional external model service.
