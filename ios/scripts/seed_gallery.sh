#!/usr/bin/env bash
# Adds a handful of photos with GPS EXIF near USC to the booted simulator for the gallery-scan demo (CLAUDE.md §11 step 4).
#   ios/scripts/seed_gallery.sh                 # 4 generated concrete-crack photos (one dated a year ago -> "Historical")
#   ios/scripts/seed_gallery.sh ~/damage/*.jpg  # your own damage photos, re-stamped with USC GPS + recent dates
# Real photos verify far better than the generated ones; shoot a few cracks/potholes around campus and pass them in.
# Needs python3 with Pillow (pip install pillow). Re-running adds duplicates; Settings > Reset in the simulator clears Photos.
set -euo pipefail
python3 -c "import PIL" 2>/dev/null || { echo "Needs Pillow: python3 -m pip install pillow" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
out="$tmp/faultline-seed"
mkdir -p "$out"

python3 - "$out" "$@" <<'PY'
import datetime, math, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageOps, ExifTags

out, sources = sys.argv[1], sys.argv[2:]
# Spots around USC (lat, lng); the map's demo region and seed_demo.sql bounties are here.
spots = [(34.0205, -118.2856), (34.0224, -118.2851), (34.0189, -118.2887), (34.0212, -118.2823), (34.0236, -118.2880)]

def dms(value):
    value = abs(value); d = int(value); m = int((value - d) * 60); s = round(((value - d) * 60 - m) * 60, 2)
    return (d, m, s)

def concrete_crack(seed):
    rnd = random.Random(seed)
    w, h = 1600, 1200
    base = Image.effect_noise((w, h), 28).convert("RGB")
    tone = Image.new("RGB", (w, h), (rnd.randint(140, 170),) * 3)
    img = Image.blend(tone, base, 0.35).filter(ImageFilter.GaussianBlur(1.2))
    draw = ImageDraw.Draw(img)
    for _ in range(900):  # aggregate speckle
        x, y, r = rnd.randrange(w), rnd.randrange(h), rnd.uniform(1, 4)
        c = rnd.randint(90, 200)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(c, c, c))
    def crack(x, y, heading, length, width):
        angle = heading
        for _ in range(length):
            angle = 0.85 * (angle + rnd.uniform(-0.4, 0.4)) + 0.15 * heading  # jagged but keeps its course
            nx, ny = x + 9 * math.cos(angle), y + 9 * math.sin(angle)
            draw.line((x, y, nx, ny), fill=(28, 26, 24), width=max(1, int(width)))
            if rnd.random() < 0.015 and width > 3:
                crack(nx, ny, angle + rnd.choice([-1, 1]) * rnd.uniform(0.6, 1.1), length // 5, width * 0.4)
            x, y, width = nx, ny, max(1.0, width * 0.995)
    crack(rnd.randint(0, 200), rnd.randint(300, 900), rnd.uniform(-0.3, 0.3), 190, rnd.uniform(7, 11))
    return img.filter(ImageFilter.GaussianBlur(0.8))

images = [ImageOps.exif_transpose(Image.open(p)).convert("RGB") for p in sources] or [concrete_crack(i) for i in range(4)]  # bake rotation; we rewrite EXIF
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
