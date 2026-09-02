// make-icon.swift — the source artwork for Crook's app icon.
//
// The icon is drawn, not painted: every curve here is geometry, so the mark is
// identical at 16pt and 1024pt and the whole thing is regenerable from this one
// file. Run it through Assets/make-icon.sh, which renders the .iconset and hands
// it to iconutil.
//
// The mark is a shepherd's crook — the app's name, and its argument: these files
// are how you steer the flock. One shape, one colour. The colour is the
// highlighter (#EFCB57), the single accent the app allows itself, on the same
// warm charcoal the editor uses for its ground. Nothing else is on the tile,
// because at 16pt nothing else would survive.
//
//   swift Assets/make-icon.swift <outdir>          # iconset PNGs + Crook.svg
//   swift Assets/make-icon.swift <outdir> --sheet  # + a legibility contact sheet

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------- design space
// Everything below is expressed in a 1024x1024 canvas with y pointing DOWN, the
// way SVG and every drawing tool does it. The CoreGraphics writer flips once, at
// the end, so no geometry in this file has to think about it.

let CANVAS = 1024.0

struct P { var x: Double; var y: Double }

func + (a: P, b: P) -> P { P(x: a.x + b.x, y: a.y + b.y) }
func - (a: P, b: P) -> P { P(x: a.x - b.x, y: a.y - b.y) }
func * (a: P, s: Double) -> P { P(x: a.x * s, y: a.y * s) }

let RAD = Double.pi / 180

// ------------------------------------------------------------------ path model
// One path description that can write itself as a CGPath or as SVG, so the PNGs
// and the .svg can never disagree about what the shape is.

enum Cmd {
    case move(P)
    case line(P)
    case cubic(P, P, P)               // c1, c2, end
    case arc(P, Double, Double, Double)  // center, radius, startAngle, endAngle (degrees, design space)
}

struct Path {
    var cmds: [Cmd] = []
    var closed = false

    mutating func move(_ p: P) { cmds.append(.move(p)) }
    mutating func line(_ p: P) { cmds.append(.line(p)) }
    mutating func cubic(_ c1: P, _ c2: P, _ e: P) { cmds.append(.cubic(c1, c2, e)) }
    mutating func arc(center: P, r: Double, from: Double, to: Double) {
        cmds.append(.arc(center, r, from, to))
    }
    mutating func close() { closed = true }

    func cgPath() -> CGPath {
        let p = CGMutablePath()
        // y-flip: design y grows downward, CoreGraphics y grows upward.
        func f(_ q: P) -> CGPoint { CGPoint(x: q.x, y: CANVAS - q.y) }
        for c in cmds {
            switch c {
            case .move(let a): p.move(to: f(a))
            case .line(let a): p.addLine(to: f(a))
            case .cubic(let c1, let c2, let e): p.addCurve(to: f(e), control1: f(c1), control2: f(c2))
            case .arc(let ctr, let r, let a0, let a1):
                // Flipping y negates angles; a decreasing CG angle is clockwise.
                let s = -a0 * RAD, e = -a1 * RAD
                p.addArc(center: f(ctr), radius: r, startAngle: s, endAngle: e, clockwise: e < s)
            }
        }
        if closed { p.closeSubpath() }
        return p
    }

    func svgD() -> String {
        func n(_ v: Double) -> String { String(format: "%.3f", v) }
        var out: [String] = []
        for c in cmds {
            switch c {
            case .move(let a): out.append("M\(n(a.x)) \(n(a.y))")
            case .line(let a): out.append("L\(n(a.x)) \(n(a.y))")
            case .cubic(let c1, let c2, let e):
                out.append("C\(n(c1.x)) \(n(c1.y)) \(n(c2.x)) \(n(c2.y)) \(n(e.x)) \(n(e.y))")
            case .arc(let ctr, let r, let a0, let a1):
                let end = P(x: ctr.x + r * cos(a1 * RAD), y: ctr.y + r * sin(a1 * RAD))
                let large = abs(a1 - a0) > 180 ? 1 : 0
                let sweep = a1 > a0 ? 1 : 0   // design space is y-down, so +angle is clockwise on screen
                out.append("A\(n(r)) \(n(r)) 0 \(large) \(sweep) \(n(end.x)) \(n(end.y))")
            }
        }
        if closed { out.append("Z") }
        return out.joined(separator: " ")
    }
}

// ------------------------------------------------------------------- the tile
// A continuous-corner rounded rectangle — the squircle macOS has used since Big
// Sur. A plain circular corner is visibly wrong next to it: the curvature jumps
// from zero to 1/r at the tangent point, and the eye reads that as a pinch. The
// construction below eases in and out of the arc (Figma's smoothing = 0.6, which
// is Apple's), so curvature ramps instead of stepping.

func squircleTile(x0: Double, y0: Double, w: Double, h: Double,
                  radius r: Double, smoothing s: Double) -> Path {
    let p = (1 + s) * r
    let arcMeasure = 90 * (1 - s)
    let alpha = (90 - arcMeasure) / 2
    let p3p4 = r * tan(alpha / 2 * RAD)
    let beta = 45 * s
    let c = p3p4 * cos(beta * RAD)
    let d = c * tan(beta * RAD)
    let arcSection = sin(arcMeasure / 2 * RAD) * r * 2.0.squareRoot()
    let b = (p - arcSection - c - d) / 3
    let a = 2 * b
    let q = p - a - b - c

    var path = Path()
    let x1 = x0 + w, y1 = y0 + h

    // Each corner: (corner point, unit vector along the incoming edge back into
    // the rect, unit vector along the outgoing edge into the rect).
    struct Corner { var pt: P; var inDir: P; var outDir: P }
    let corners = [
        Corner(pt: P(x: x1, y: y0), inDir: P(x: -1, y: 0), outDir: P(x: 0, y:  1)), // TR
        Corner(pt: P(x: x1, y: y1), inDir: P(x: 0, y: -1), outDir: P(x: -1, y: 0)), // BR
        Corner(pt: P(x: x0, y: y1), inDir: P(x:  1, y: 0), outDir: P(x: 0, y: -1)), // BL
        Corner(pt: P(x: x0, y: y0), inDir: P(x: 0, y:  1), outDir: P(x:  1, y: 0)), // TL
    ]

    path.move(corners[3].pt + corners[3].outDir * p)   // start on the top edge
    for k in corners {
        let u = k.inDir, v = k.outDir
        path.line(k.pt + u * p)
        path.cubic(k.pt + u * (p - a),
                   k.pt + u * (p - a - b),
                   k.pt + u * q + v * d)
        let ctr = k.pt + u * r + v * r
        let s0 = atan2((u * q + v * d - (u * r + v * r)).y,
                       (u * q + v * d - (u * r + v * r)).x) / RAD
        let s1 = atan2((u * d + v * q - (u * r + v * r)).y,
                       (u * d + v * q - (u * r + v * r)).x) / RAD
        var e = s1
        while e - s0 >  180 { e -= 360 }
        while s0 - e >  180 { e += 360 }
        path.arc(center: ctr, r: r, from: s0, to: e)
        // The mirror of the first cubic across the corner's diagonal: its
        // controls sat exactly on the incoming edge, so these sit exactly on the
        // outgoing one. Nudging them off it costs the tangency and the tile goes
        // subtly lopsided.
        path.cubic(k.pt + v * (p - a - b),
                   k.pt + v * (p - a),
                   k.pt + v * p)
    }
    path.close()
    return path
}

// ------------------------------------------------------------------- the crook
// A stroked centreline would be the easy route, but a real crook is not a pipe:
// the shaft is heavier than the hook, and the hook tightens as it curls. Both are
// carried here by sampling the centreline and offsetting it by a width that
// varies along the run, which also means the outline is a plain filled path with
// no stroke to scale wrong.

struct Crook {
    var shaftWidth = 150.0     // stroke at the foot of the staff, in canvas units
    var tipRatio   = 0.90      // stroke at the hook's tip, as a fraction of it
    var radius     = 175.0     // centreline radius where the hook leaves the staff
    var curl       = 0.10      // how much the hook tightens by the tip. Past ~0.15 the
                               // curl closes into a spiral and the mark turns clumsy big.
    var sweep      = 175.0     // degrees of hook. Two letterforms bracket this
                               // number: past ~250 the hook closes on the staff
                               // and the mark reads as a "q", and around ~210 the
                               // tip runs back down parallel to the staff, giving
                               // the two vertical legs of an "n". Stopping near a
                               // half turn leaves a hook, not a letter.
    var shaftLen   = 470.0     // centreline length of the straight run. Read
                               // together with radius: a crook is a LONG staff
                               // carrying a comparatively small hook, and when
                               // the hook's diameter approaches the staff's
                               // length the silhouette stops being a tool.
}

func crookOutline(_ k: Crook, samples: Int = 320, capSteps: Int = 28) -> Path {
    let cx = 0.0, cy = 0.0                 // hook centre; the whole mark is re-centred later
    let sx = cx + k.radius                 // the staff is tangent to the hook circle
    let yFoot = cy + k.shaftLen

    // Sample the centreline as (point, tangent) pairs, staff first.
    var pts: [P] = [], tans: [P] = []
    let nShaft = max(2, samples / 8)
    for i in 0...nShaft {
        let f = Double(i) / Double(nShaft)
        pts.append(P(x: sx, y: yFoot + (cy - yFoot) * f))
        tans.append(P(x: 0, y: -1))        // running up the page
    }
    let nHook = samples
    for i in 1...nHook {
        let f = Double(i) / Double(nHook)
        let ang = k.sweep * f * RAD
        // Radius eases inward quadratically so the joint with the staff stays
        // exactly tangent (dR/dangle is zero at angle zero).
        let r = k.radius * (1 - k.curl * f * f)
        let dr = -k.radius * k.curl * 2 * f / (k.sweep * RAD)
        pts.append(P(x: cx + r * cos(ang), y: cy - r * sin(ang)))
        var t = P(x: dr * cos(ang) - r * sin(ang), y: -(dr * sin(ang) + r * cos(ang)))
        let m = (t.x * t.x + t.y * t.y).squareRoot()
        t = t * (1 / m)
        tans.append(t)
    }

    // Arc length, so the taper is distributed by distance rather than by index.
    var s: [Double] = [0]
    for i in 1..<pts.count {
        let d = pts[i] - pts[i - 1]
        s.append(s[i - 1] + (d.x * d.x + d.y * d.y).squareRoot())
    }
    let total = s.last!
    let shaftFrac = s[nShaft] / total

    func width(_ i: Int) -> Double {
        let f = s[i] / total
        guard f > shaftFrac else { return k.shaftWidth }
        let u = (f - shaftFrac) / (1 - shaftFrac)
        let e = u * u * (3 - 2 * u)        // smoothstep: no crease where the taper starts
        return k.shaftWidth * (1 - e * (1 - k.tipRatio))
    }

    func normal(_ i: Int) -> P { P(x: -tans[i].y, y: tans[i].x) }

    var path = Path()
    let n0 = normal(0)
    path.move(pts[0] + n0 * (width(0) / 2))
    for i in 1..<pts.count { path.line(pts[i] + normal(i) * (width(i) / 2)) }

    // Round the tip: sweep the offset point half a turn through the tangent.
    let last = pts.count - 1
    let rTip = width(last) / 2
    let aTip = atan2(normal(last).y, normal(last).x) / RAD
    for j in 1...capSteps {
        let ang = (aTip - 180 * Double(j) / Double(capSteps)) * RAD
        path.line(pts[last] + P(x: cos(ang), y: sin(ang)) * rTip)
    }
    for i in stride(from: last - 1, through: 0, by: -1) {
        path.line(pts[i] - normal(i) * (width(i) / 2))
    }
    // and the foot.
    let rFoot = width(0) / 2
    let aFoot = atan2(-n0.y, -n0.x) / RAD
    for j in 1...capSteps {
        let ang = (aFoot - 180 * Double(j) / Double(capSteps)) * RAD
        path.line(pts[0] + P(x: cos(ang), y: sin(ang)) * rFoot)
    }
    path.close()
    return path
}

// ------------------------------------------------------------------ composition

struct Design {
    // The Big Sur grid: a 824pt tile on a 1024pt canvas, centred. Sizing to the
    // same grid as every other Mac app is the whole point — an icon that ignores
    // it sits visibly too large or too small in the Dock.
    var tile = 824.0
    var cornerRadius = 0.2237          // of the tile's side, per Apple's grid
    var smoothing = 0.6
    var markHeight = 0.72              // of the tile
    var opticalDrop = 0.020            // nudge down; a hooked mark is top-heavy

    var ground = (0x1D, 0x1C, 0x19)    // the editor's warm charcoal
    var ink    = (0xEF, 0xCB, 0x57)    // the highlighter, the one accent
}

func hex(_ t: (Int, Int, Int)) -> CGColor {
    CGColor(red: CGFloat(t.0) / 255, green: CGFloat(t.1) / 255,
            blue: CGFloat(t.2) / 255, alpha: 1)
}

func bbox(of path: Path) -> (minx: Double, miny: Double, maxx: Double, maxy: Double) {
    var mnx = Double.infinity, mny = Double.infinity
    var mxx = -Double.infinity, mxy = -Double.infinity
    func acc(_ p: P) { mnx = min(mnx, p.x); mny = min(mny, p.y); mxx = max(mxx, p.x); mxy = max(mxy, p.y) }
    for c in path.cmds {
        switch c {
        case .move(let a), .line(let a): acc(a)
        case .cubic(let a, let b, let e): acc(a); acc(b); acc(e)
        case .arc(let ctr, let r, _, _):
            // Only ever called on the mark, which is all line segments; a whole-
            // circle bound is a safe over-estimate if that ever changes.
            acc(P(x: ctr.x - r, y: ctr.y - r)); acc(P(x: ctr.x + r, y: ctr.y + r))
        }
    }
    return (mnx, mny, mxx, mxy)
}

func transformed(_ path: Path, scale: Double, dx: Double, dy: Double) -> Path {
    func f(_ p: P) -> P { P(x: p.x * scale + dx, y: p.y * scale + dy) }
    var out = Path()
    out.closed = path.closed
    out.cmds = path.cmds.map { c in
        switch c {
        case .move(let a): return .move(f(a))
        case .line(let a): return .line(f(a))
        case .cubic(let a, let b, let e): return .cubic(f(a), f(b), f(e))
        case .arc(let ctr, let r, let a0, let a1): return .arc(f(ctr), r * scale, a0, a1)
        }
    }
    return out
}

struct Artwork { var tile: Path; var mark: Path; var d: Design }

func buildArtwork(_ d: Design, _ k: Crook) -> Artwork {
    let inset = (CANVAS - d.tile) / 2
    let tile = squircleTile(x0: inset, y0: inset, w: d.tile, h: d.tile,
                            radius: d.tile * d.cornerRadius, smoothing: d.smoothing)

    var mark = crookOutline(k)
    let bb = bbox(of: mark)
    let scale = (d.tile * d.markHeight) / (bb.maxy - bb.miny)
    // Centre the mark's own bounding box on the tile, then nudge optically.
    let cxWant = CANVAS / 2, cyWant = CANVAS / 2 + d.tile * d.opticalDrop
    let dx = cxWant - (bb.minx + bb.maxx) / 2 * scale
    let dy = cyWant - (bb.miny + bb.maxy) / 2 * scale
    mark = transformed(mark, scale: scale, dx: dx, dy: dy)
    return Artwork(tile: tile, mark: mark, d: d)
}

// ------------------------------------------------------------------- rendering

func renderImage(_ art: Artwork, size: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let s = Double(size) / CANVAS
    ctx.scaleBy(x: s, y: s)

    ctx.addPath(art.tile.cgPath())
    ctx.setFillColor(hex(art.d.ground))
    ctx.fillPath()

    ctx.addPath(art.mark.cgPath())
    ctx.setFillColor(hex(art.d.ink))
    ctx.fillPath()

    guard let img = ctx.makeImage() else { fatalError("no image") }
    return img
}

func writePNG(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("no destination") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func writeSVG(_ art: Artwork, to url: URL) {
    func h(_ t: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", t.0, t.1, t.2) }
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <!-- Crook. Generated by Assets/make-icon.swift, which is the source of
           truth; edit that and re-run Assets/make-icon.sh rather than this file.
           The tile is the Big Sur 824/1024 grid with a continuous corner; the
           mark is a shepherd's crook, tapered from shaft to tip. -->
      <title>Crook</title>
      <path fill="\(h(art.d.ground))" d="\(art.tile.svgD())"/>
      <path fill="\(h(art.d.ink))" d="\(art.mark.svgD())"/>
    </svg>

    """
    try! svg.write(to: url, atomically: true, encoding: .utf8)
}

// A contact sheet: every size that matters, drawn at 1:1 and again magnified
// with no smoothing, over light and dark grounds. The only honest way to answer
// "does it still read at 16pt", which is the question this icon has to pass.
func renderSheet(_ art: Artwork, to url: URL) {
    let zooms: [(Int, Int)] = [(16, 8), (32, 4), (64, 2), (128, 1)]
    let actual = [16, 16, 16, 32, 32, 64]
    let pad = 16.0, cell = 128.0, band = 96.0
    let w = pad + Double(zooms.count) * (cell + pad)
    let h = pad + cell + pad + band

    let ctx = CGContext(data: nil, width: Int(w * 2), height: Int(h * 2), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    ctx.setFillColor(CGColor(red: 0.56, green: 0.55, blue: 0.53, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // The two grounds an icon actually lands on: a dark Dock, a light Finder.
    ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.12, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: band))
    ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1))
    ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: band))

    // Magnified, nearest-neighbour, so every pixel decision is visible.
    ctx.interpolationQuality = .none
    var x = pad
    for (size, _) in zooms {
        ctx.draw(renderImage(art, size: size), in: CGRect(x: x, y: band + pad, width: cell, height: cell))
        x += cell + pad
    }
    // And at life size, twice, on each ground.
    for (i, ground) in [0.0, w / 2].enumerated() {
        _ = i
        var x2 = ground + pad
        for size in actual {
            ctx.draw(renderImage(art, size: size),
                     in: CGRect(x: x2, y: (band - Double(size)) / 2, width: Double(size), height: Double(size)))
            x2 += Double(size) + 12
        }
    }
    writePNG(ctx.makeImage()!, to: url)
}

// ----------------------------------------------------------------------- main

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let wantSheet = args.contains("--sheet")

// Every number in the design is overridable from the environment, which is how
// the shipped values were found: sweep the parameter, render, read the 16pt
// pixels, keep what survives.
func env(_ name: String, _ fallback: Double) -> Double {
    if let v = ProcessInfo.processInfo.environment[name], let d = Double(v) { return d }
    return fallback
}

var design = Design()
design.markHeight = env("CROOK_MARK_HEIGHT", design.markHeight)
design.opticalDrop = env("CROOK_OPTICAL_DROP", design.opticalDrop)

var crook = Crook()
crook.shaftWidth = env("CROOK_SHAFT_W", crook.shaftWidth)
crook.tipRatio = env("CROOK_TIP_RATIO", crook.tipRatio)
crook.radius = env("CROOK_RADIUS", crook.radius)
crook.curl = env("CROOK_CURL", crook.curl)
crook.sweep = env("CROOK_SWEEP", crook.sweep)
crook.shaftLen = env("CROOK_SHAFT_LEN", crook.shaftLen)

let art = buildArtwork(design, crook)

let fm = FileManager.default
let iconset = outDir.appendingPathComponent("Crook.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    writePNG(renderImage(art, size: px), to: iconset.appendingPathComponent("\(name).png"))
}
writeSVG(art, to: outDir.appendingPathComponent("Crook.svg"))
if wantSheet { renderSheet(art, to: outDir.appendingPathComponent("contact-sheet.png")) }

let bb = bbox(of: art.mark)
let markH = bb.maxy - bb.miny
let rawH = { () -> Double in let r = bbox(of: crookOutline(crook)); return r.maxy - r.miny }()
let shaft = crook.shaftWidth * markH / rawH
FileHandle.standardError.write("""
tile      \(Int(design.tile)) of \(Int(CANVAS))   corner r=\(String(format: "%.1f", design.tile * design.cornerRadius)) smoothing \(design.smoothing)
mark      \(String(format: "%.0f", bb.maxx - bb.minx)) x \(String(format: "%.0f", markH))  (\(String(format: "%.0f", markH / design.tile * 100))% of the tile)
shaft     \(String(format: "%.1f", shaft)) units = \(String(format: "%.2f", shaft * 16 / CANVAS))px at 16pt
wrote     \(iconset.path)

""".data(using: .utf8)!)
