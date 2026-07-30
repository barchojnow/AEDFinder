import Toybox.Graphics;
import Toybox.Lang;

// The heart-and-bolt mark, drawn with primitives rather than shipped as
// a bitmap.
//
// ZabkaFinder needed ten pre-scaled PNGs and a variants/ folder wired
// into monkey.jungle product by product, because runtime bitmap scaling
// isn't available on every Connect IQ level and looks poor where it is.
// A shape made of circles and polygons has neither problem: it is
// resolution-independent by construction, so one function covers every
// screen from a 208 px Forerunner to a 454 px Fenix, costs no resource
// memory, and needs no per-device jungle entry. The launcher icon still
// has to be a real bitmap - that one Garmin renders itself.
module AedLogo {

    // Draws the mark centred on (cx, cy) with the given overall size in
    // pixels. All offsets are fractions of `size`, so the proportions
    // hold at any scale.
    function draw(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float,
                  size as Lang.Float, color as Graphics.ColorType) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        // Heart: two lobes plus the point below them. Drawing it as
        // circles + polygon rather than an arc path keeps it to three
        // calls, which matters on a widget that redraws on every
        // compass event.
        var lobeR = 0.27 * size;
        var lobeY = cy - 0.16 * size;
        var lobeX = 0.24 * size;

        dc.fillCircle(cx - lobeX, lobeY, lobeR);
        dc.fillCircle(cx + lobeX, lobeY, lobeR);
        dc.fillPolygon([
            [cx - (lobeX + lobeR) + 0.02 * size, lobeY + 0.04 * size],
            [cx + (lobeX + lobeR) - 0.02 * size, lobeY + 0.04 * size],
            [cx, cy + 0.46 * size]
        ]);

        // Lightning bolt, punched through the heart in the background
        // colour so the mark reads at small sizes without needing an
        // outline.
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([
            [cx + 0.10 * size, cy - 0.30 * size],
            [cx - 0.14 * size, cy + 0.02 * size],
            [cx - 0.01 * size, cy + 0.02 * size],
            [cx - 0.09 * size, cy + 0.32 * size],
            [cx + 0.15 * size, cy - 0.02 * size],
            [cx + 0.01 * size, cy - 0.02 * size]
        ]);
    }
}
