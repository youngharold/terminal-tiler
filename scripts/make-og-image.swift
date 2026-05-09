#!/usr/bin/env swift
// Generates og-image.png (1280×640) at the repo root.
// Run from the repo root: ./scripts/make-og-image.swift
//
// Output is the social preview shown when the GitHub repo URL is shared anywhere
// (Twitter, Slack, Discord, LinkedIn, blog posts). After regenerating, upload it
// via Repo Settings → Social preview — GitHub doesn't pull from a file in the repo.

import AppKit
import CoreGraphics

// 1.6:1 aspect ratio recommended; 1280×640 hits OG/Twitter card sweet spot.
let W: CGFloat = 1280, H: CGFloat = 640
let canvas = CGRect(x: 0, y: 0, width: W, height: H)

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no CG context")
}

// Background: dark vertical gradient (charcoal → near-black).
let colorSpace = CGColorSpaceCreateDeviceRGB()
let topColor   = CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
let botColor   = CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topColor, botColor] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: H),
    end:   CGPoint(x: 0, y: 0),
    options: []
)

// Subtle accent: a violet glow in the top-right corner.
let accent = CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.18)  // #7C3AED
ctx.setFillColor(accent)
ctx.fillEllipse(in: CGRect(x: W - 480, y: H - 380, width: 700, height: 700))

// Subtle accent: warm "Claude Code" orange in bottom-left.
let warm = CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 0.14)  // #D97757
ctx.setFillColor(warm)
ctx.fillEllipse(in: CGRect(x: -240, y: -300, width: 600, height: 600))

// Right side: a stylized 4×3 mini-grid representing tiled terminal windows.
let gridX: CGFloat = 760
let gridY: CGFloat = 100
let gridW: CGFloat = 460
let gridH: CGFloat = 360
let cols = 4, rows = 3
let gap: CGFloat = 12
let cellW = (gridW - CGFloat(cols - 1) * gap) / CGFloat(cols)
let cellH = (gridH - CGFloat(rows - 1) * gap) / CGFloat(rows)

ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0))
ctx.setStrokeColor(CGColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1.0))
ctx.setLineWidth(1.5)

// Highlighted "focused" tile is the second-row, second-column.
let focusedRow = 1, focusedCol = 1

for r in 0..<rows {
    for c in 0..<cols {
        let x = gridX + CGFloat(c) * (cellW + gap)
        let y = gridY + CGFloat(rows - 1 - r) * (cellH + gap)
        let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        if r == focusedRow && c == focusedCol {
            ctx.setFillColor(CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.85))
        } else {
            ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0))
        }
        ctx.addPath(path)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.strokePath()

        // Three colored "traffic light" dots in each tile to read as a window.
        let dotSize: CGFloat = 5
        let dotY = y + cellH - 12
        let dotColors: [CGColor] = [
            CGColor(red: 0.99, green: 0.36, blue: 0.36, alpha: 0.55),  // red
            CGColor(red: 0.99, green: 0.78, blue: 0.27, alpha: 0.55),  // yellow
            CGColor(red: 0.30, green: 0.80, blue: 0.36, alpha: 0.55),  // green
        ]
        for (i, dc) in dotColors.enumerated() {
            ctx.setFillColor(dc)
            ctx.fillEllipse(in: CGRect(x: x + 8 + CGFloat(i) * 9, y: dotY, width: dotSize, height: dotSize))
        }

        // A few prompt-line strokes inside each tile to suggest terminal output.
        ctx.setStrokeColor(CGColor(red: 0.30, green: 0.80, blue: 0.36, alpha: 0.40))
        ctx.setLineWidth(1.0)
        for line in 0..<3 {
            let ly = y + cellH - 28 - CGFloat(line) * 8
            ctx.move(to: CGPoint(x: x + 8, y: ly))
            ctx.addLine(to: CGPoint(x: x + cellW - 12 - CGFloat(line) * 14, y: ly))
            ctx.strokePath()
        }
    }
}

// Headline + subtitle on the left side.
func draw(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

draw("TERMUSHER",
     at: CGPoint(x: 60, y: H - 130),
     size: 64, color: .white, weight: .heavy, kern: -1.5)

draw("seats your terminal windows",
     at: CGPoint(x: 64, y: H - 175),
     size: 26, color: NSColor(white: 0.78, alpha: 1.0), weight: .medium)

draw("Tile · zoom · drag-to-reorder · auto-return on idle",
     at: CGPoint(x: 64, y: 230),
     size: 22, color: NSColor(white: 0.55, alpha: 1.0))

draw("For developers running multiple Claude Code / Codex / Cursor sessions.",
     at: CGPoint(x: 64, y: 195),
     size: 18, color: NSColor(white: 0.45, alpha: 1.0))

draw("github.com/youngharold/termusher",
     at: CGPoint(x: 64, y: 60),
     size: 18, color: NSColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1.0), weight: .medium)

img.unlockFocus()

// Encode as PNG.
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}

let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("og-image.png")
try png.write(to: outURL)
print("wrote \(outURL.path) (\(png.count) bytes, \(Int(W))×\(Int(H)))")
