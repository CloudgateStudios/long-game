#!/bin/sh
# Renders the app icons from the SVG artwork in Design/ into the asset catalog.
# Uses only tools that ship with macOS. Run from the project root: sh Scripts/make_icons.sh
set -e
OUT="LongGame/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

qlmanage -t -s 1024 -o "$TMP" Design/app-icon.svg Design/app-icon-mac.svg >/dev/null 2>&1

# iOS icons must be opaque, so the alpha channel is dropped by redrawing on a solid canvas.
cat > "$TMP/flatten.swift" <<'SWIFT'
import AppKit
let arguments = CommandLine.arguments
guard let image = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
SWIFT
swift "$TMP/flatten.swift" "$TMP/app-icon.svg.png" "$OUT/icon-ios-1024.png"

for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$TMP/app-icon-mac.svg.png" --out "$OUT/icon-mac-$size.png" >/dev/null
done
echo "Icons written to $OUT"
