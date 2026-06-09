#!/bin/sh
# FbdevDemo.sh - launch the flutter_fbdev demo from a Knulli/Batocera Ports menu.
# Sits next to the deployed bundle dir `fbdevdemo/`. Quit with Volume or Power.
# (Audio is played by the embedder itself - see FbdevAudio - so there's nothing
# to start here.)
DIR="$(dirname "$0")/fbdevdemo"
cd "$DIR" || { echo "bundle not found: $DIR" >&2; exit 1; }
chmod +x ./flutter_fbdev 2>/dev/null   # SD/SMB copies can drop the exec bit
# UI scale comes from the embedder's default device-pixel-ratio (1.25, tuned for
# this panel). Override here with `export FBDEV_PIXEL_RATIO=1.5` if you want.
./flutter_fbdev "$DIR" > "$DIR/run.log" 2>&1
