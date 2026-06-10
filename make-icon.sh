#!/bin/bash
# Generate AppIcon.icns: dark squircle + Claude-clay battery ring + spark.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/icongen.m" <<'OBJC'
#import <Cocoa/Cocoa.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const CGFloat S = 1024;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext =
            [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

        // Squircle background with the standard ~10% margin.
        NSRect r = NSMakeRect(100, 100, 824, 824);
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:185 yRadius:185];
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:
                [NSColor colorWithRed:0.16 green:0.16 blue:0.18 alpha:1]
            endingColor:[NSColor colorWithRed:0.09 green:0.09 blue:0.10 alpha:1]];
        [g drawInBezierPath:bg angle:-90];

        // Battery ring, Claude clay color, 72% sweep.
        NSPoint c = NSMakePoint(512, 512);
        CGFloat R = 250, LW = 78;
        NSBezierPath *track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:c radius:R startAngle:0 endAngle:360];
        [[NSColor colorWithWhite:1 alpha:0.13] setStroke];
        track.lineWidth = LW; [track stroke];
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:c radius:R
            startAngle:90 endAngle:90 - 360*0.72 clockwise:YES];
        [[NSColor colorWithRed:0.85 green:0.47 blue:0.34 alpha:1] setStroke]; // clay
        arc.lineWidth = LW; arc.lineCapStyle = NSLineCapStyleRound; [arc stroke];

        // Center spark (six rays).
        [[NSColor colorWithRed:0.93 green:0.91 blue:0.89 alpha:1] setStroke];
        for (int i = 0; i < 6; i++) {
            CGFloat a = i * M_PI / 3 + M_PI / 6;
            NSBezierPath *ray = [NSBezierPath bezierPath];
            [ray moveToPoint:NSMakePoint(c.x + cos(a)*28,  c.y + sin(a)*28)];
            [ray lineToPoint:NSMakePoint(c.x + cos(a)*108, c.y + sin(a)*108)];
            ray.lineWidth = 40; ray.lineCapStyle = NSLineCapStyleRound; [ray stroke];
        }

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@(argv[1]) atomically:YES];
    }
    return 0;
}
OBJC

clang -framework Cocoa -fobjc-arc "$WORK/icongen.m" -o "$WORK/icongen"
"$WORK/icongen" "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz       "$WORK/icon-1024.png" --out "$ICONSET/icon_${sz}x${sz}.png"      >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
echo "✓ AppIcon.icns generated"
