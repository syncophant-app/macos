# Assets

| File | Purpose |
| --- | --- |
| `AppIcon.svg` | Brand app icon, vector source (1024×1024), from the Syncophant brand kit. |
| `AppIcon-small.svg` | Small cut of the app icon (wider sync gaps) for the 16 and 32 px sizes. |
| `AppIcon-1024.png` | Flattened master export of the SVG. |
| `AppIcon.iconset/` | 10 PNGs: 16, 32, 128, 256, 512 at 1x and @2x. |
| `AppIcon.icns` | Final bundle icon (`iconutil -c icns`). Info.plist: `CFBundleIconFile` = `AppIcon`. |
| `Logo.svg` | Black elephant logo on a 1024×1024 canvas, one flattened path. |
| `MenuBarIcon.svg` | Menu bar version of the logo: tight bounds, pure black, for use as a template image. |

## Logo (sync gaps)

The gaps between the ears and the head are cut as two halves of a clockwise sync loop. The left gap rises from below the ear and ends in an up arrow. The right gap drops from above the ear and ends in a down arrow. Each ear joins the head beyond its arrow, so both arrowheads are fully enclosed. The cuts are true holes, so the logo works on any background.

- **Head:** 317.6 px wide, straight sides. Top corners r 109, bottom corners r 97.7. Mirror axis x = 512.
- **Logo.svg:** gap 26 px, arrowhead 58 px wide × 52 px long, placed 8° into the corner arc.
- **MenuBarIcon.svg:** gap 48 px, arrowhead 112 × 84 px, placed at the end of the straight side. Wider cuts survive at 16 pt; at @1x the arrows blur into the gaps.
- Below about 48 px, use `MenuBarIcon.svg` instead of `Logo.svg`. The thin gaps in `Logo.svg` close up at that size.

## App icon

The white mark on a Syncophant Blue glass tile: `#4DA3FF` to `#0A5FDB`, 824 px tile with 185 px corners on the 1024 px canvas (macOS grid), a thin light rim and a soft top sheen. The sync gaps show the tile through. This is the only place the mark is blue or sits on a gradient. No text or badges on the tile.

- 128 px and up: downscaled from `AppIcon-1024.png`.
- 16 and 32 px (and their @2x): rendered from `AppIcon-small.svg`, whose wider gaps survive at that size.

## Regenerate

```sh
# SVG -> PNG with alpha (ImageMagick's own SVG renderer drops gradients/filters; use Chrome)
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$chrome" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot=AppIcon-1024.png file://$PWD/AppIcon.svg
for s in 16 32 64; do   # the small cut, for 16 and 32 px at 1x and 2x
  "$chrome" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=$s,$s --screenshot=small-$s.png "data:text/html,<body style='margin:0'><img src='file://$PWD/AppIcon-small.svg' width=$s height=$s>"
done
cp small-16.png AppIcon.iconset/icon_16x16.png; cp small-32.png AppIcon.iconset/icon_16x16@2x.png
cp small-32.png AppIcon.iconset/icon_32x32.png; cp small-64.png AppIcon.iconset/icon_32x32@2x.png
for s in 128 256 512; do
  sips -z $s $s AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```
