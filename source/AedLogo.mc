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
    //
    // The V meets the lobes at their TANGENT POINTS, not at an arbitrary
    // inset. Anywhere else and the circle bulges past the straight edge,
    // leaving a step in the silhouette that is obvious at 500 px and
    // just looks like a bad render at 35.
    //
    // TANGENT_X/Y are derived from the four constants below - see
    // tools/test_logo_geometry.py, which recomputes them and fails if
    // anyone retunes a lobe without retuning these. Precomputed rather
    // than solved here because draw() runs on every compass event.
    const TANGENT_X = 0.430510;
    const TANGENT_Y = 0.031327;

    function draw(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float,
                  size as Lang.Float, color as Graphics.ColorType) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        var lobeR = 0.27 * size;
        var lobeY = cy - 0.16 * size;
        var lobeX = 0.24 * size;

        dc.fillCircle(cx - lobeX, lobeY, lobeR);
        dc.fillCircle(cx + lobeX, lobeY, lobeR);
        // The middle vertex sits at lobe-centre height. Below y = -0.036
        // the two circles no longer overlap, so a straight edge between
        // the tangent points (y = +0.031) would leave the cleavage
        // unfilled - a hole punched through the middle of the heart.
        dc.fillPolygon([
            [cx - TANGENT_X * size, cy + TANGENT_Y * size],
            [cx, lobeY],
            [cx + TANGENT_X * size, cy + TANGENT_Y * size],
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
