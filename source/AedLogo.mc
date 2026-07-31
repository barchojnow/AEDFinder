import Toybox.Graphics;
import Toybox.Lang;

// The heart-and-bolt mark, drawn rather than shipped as a bitmap.
// Runtime bitmap scaling isn't available on every CIQ level and looks
// poor where it is, so ZabkaFinder needed ten pre-scaled PNGs and a
// per-product jungle mapping. Circles and polygons scale for free.
//
// Geometry is mirrored in tools/make_icons.py, which generates the
// launcher icons - those must be real bitmaps, Garmin renders them.
module AedLogo {

    // All offsets are fractions of `size`, so proportions hold at any
    // scale from a 208 px Forerunner to a 454 px Fenix.
    function draw(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float,
                  size as Lang.Float, color as Graphics.ColorType) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

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

        // Punched through in the background colour, so the mark reads at
        // small sizes without needing an outline.
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
