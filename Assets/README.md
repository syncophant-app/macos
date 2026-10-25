# Assets

| File | Purpose |
| --- | --- |
| `AppIcon.svg` | Hand-authored vector source (1024×1024). Edit this, then re-export. |
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

## Mark (original, no third-party or SF Symbol artwork)

- **Tile:** 824×824 rounded rect (rx 185) centered on the 1024 canvas (macOS icon grid, 100 px margin), vertical blue gradient `#4DA3FF` → `#0A5FDB`, soft black drop shadow (dy 14, blur 14, 28%).
- **Elephant head and trunk:** one continuous white→`#DCEBFF` path. Round head about 328 px wide centered at x=512; the trunk drops from the right of the chin and ends in a rounded curl toward the left, so it reads as a trunk even at 32 px. Soft blue shadow (`#06307A`, 35%) separates it from the tile.
- **Eyes:** two `#0A5FDB` dots, r 22, at (448, 456) and (576, 456).
- **Ears as sync rings:** two 54 px round-capped strokes, white at 62% opacity, radius 150, each an open ring of about 270° with its gap facing the head. Left ring is centered at (370, 470) and right ring at (654, 470). Together they read as ears and as a two-sided sync loop, and the circular disc form hints at storage media.
- No text, no fine detail; smallest feature (eye) is 44 px at 1024.

## Regenerate

```sh
# SVG -> PNG with alpha (ImageMagick's own SVG renderer drops gradients/filters; use Chrome)
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
  --hide-scrollbars --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot=AppIcon-1024.png file://$PWD/AppIcon.svg
for s in 16 32 128 256 512; do
  magick AppIcon-1024.png -filter Lanczos -resize ${s}x${s} AppIcon.iconset/icon_${s}x${s}.png
  magick AppIcon-1024.png -filter Lanczos -resize $((s*2))x$((s*2)) AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```
