#!/usr/bin/env bash
# Adds a handful of photos with GPS EXIF near USC to the booted simulator for the gallery-scan demo (CLAUDE.md §11 step 4).
#   ios/scripts/seed_gallery.sh                 # the 4 real damage photos in seed_photos/ (Wikimedia Commons, see CREDITS.md)
#   ios/scripts/seed_gallery.sh ~/damage/*.jpg  # your own damage photos instead
# Either way they're re-stamped with USC GPS and recent dates (the second one a year ago -> "Historical").
# Needs python3 with Pillow (pip install pillow). Re-running adds duplicates; Settings > Reset in the simulator clears Photos.
set -euo pipefail
python3 -c "import PIL" 2>/dev/null || { echo "Needs Pillow: python3 -m pip install pillow" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
out="$tmp/faultline-seed"
mkdir -p "$out"

[ $# -gt 0 ] || set -- "$(dirname "$0")"/seed_photos/*.jpg
python3 - "$out" "$@" <<'PY'
import datetime, random, sys
from PIL import Image, ImageOps, ExifTags

out, sources = sys.argv[1], sys.argv[2:]
# Spots around USC (lat, lng); the map's demo region and seed_demo.sql bounties are here.
spots = [(34.0205, -118.2856), (34.0224, -118.2851), (34.0189, -118.2887), (34.0212, -118.2823), (34.0236, -118.2880)]

def dms(value):
    value = abs(value); d = int(value); m = int((value - d) * 60); s = round(((value - d) * 60 - m) * 60, 2)
    return (d, m, s)

images = [ImageOps.exif_transpose(Image.open(p)).convert("RGB") for p in sources]  # bake rotation; we rewrite EXIF
now = datetime.datetime.now()
for i, img in enumerate(images):
    lat, lng = spots[i % len(spots)]
    lat += random.uniform(-0.0004, 0.0004); lng += random.uniform(-0.0004, 0.0004)
    taken = now - (datetime.timedelta(days=380) if i == 1 else datetime.timedelta(hours=2 + 20 * i))
    stamp = taken.strftime("%Y:%m:%d %H:%M:%S")
    exif = Image.Exif()
    exif[ExifTags.Base.DateTime] = stamp
    exif.get_ifd(ExifTags.IFD.Exif)[ExifTags.Base.DateTimeOriginal] = stamp
    exif[ExifTags.IFD.GPSInfo] = {
        ExifTags.GPS.GPSLatitudeRef: "N" if lat >= 0 else "S", ExifTags.GPS.GPSLatitude: dms(lat),
        ExifTags.GPS.GPSLongitudeRef: "E" if lng >= 0 else "W", ExifTags.GPS.GPSLongitude: dms(lng),
    }
    path = f"{out}/faultline_seed_{i + 1}.jpg"
    img.save(path, "JPEG", quality=85, exif=exif)
    print(path)
PY

xcrun simctl addmedia booted "$out"/*.jpg
echo "Added $(ls "$out" | wc -l | tr -d ' ') photos near USC to the booted simulator."
