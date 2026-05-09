#!/usr/bin/env swift
// Generates wiki/zoom-modes.png — a 2×2 panel showing each zoom mode visually.
// Run: ./scripts/make-zoom-modes-diagram.swift <output-path>
//
// Each panel: a stylized "screen" with 12 windows (4×3 grid). Highlights show how
// the focused window expands under each mode. Other windows: dark; focused: violet.

import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: make-zoom-modes-diagram.swift <output.png>\n", stderr)
    exit(1)
}
let outPath = CommandLine.arguments[1]

let W: CGFloat = 1600, H: CGFloat = 900
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// Background
ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

let cols = 4, rows = 3
let focusedR = 1, focusedC = 1  // second row, second column from the top-left

// Each panel is one quadrant of the canvas with padding
let panelGap: CGFloat = 60
let titleH: CGFloat = 60
let panelW = (W - panelGap * 3) / 2
let panelH = (H - titleH * 2 - panelGap * 3) / 2

func drawString(_ text: String, at point: CGPoint, size: CGFloat,
                color: NSColor, weight: NSFont.Weight = .regular) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

struct Panel {
    let title: String
    let subtitle: String
    let originX: CGFloat
    let originY: CGFloat
    let render: (_ ctx: CGContext, _ rect: CGRect) -> Void
}

func grid(_ ctx: CGContext, in screen: CGRect,
          cols: Int, rows: Int, gap: CGFloat,
          highlight: ((Int, Int) -> Bool)? = nil,
          focusedRect: CGRect? = nil) {
    let cellW = (screen.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
    let cellH = (screen.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
    for r in 0..<rows {
        for c in 0..<cols {
            let x = screen.minX + CGFloat(c) * (cellW + gap)
            let y = screen.minY + screen.height - cellH - CGFloat(r) * (cellH + gap)
            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
            let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            let isFocus = highlight?(r, c) ?? false
            ctx.setFillColor(isFocus
                ? CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.85)
                : CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0))
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(CGColor(red: 0.30, green: 0.32, blue: 0.36, alpha: 1.0))
            ctx.setLineWidth(1.0)
            ctx.addPath(path); ctx.strokePath()
        }
    }
    if let f = focusedRect {
        let path = CGPath(roundedRect: f, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.92))
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.62, green: 0.42, blue: 0.95, alpha: 1.0))
        ctx.setLineWidth(2.0)
        ctx.addPath(path); ctx.strokePath()
    }
}

func panelRect(col: Int, row: Int) -> CGRect {
    let x = panelGap + CGFloat(col) * (panelW + panelGap)
    let y = H - titleH - CGFloat(row + 1) * panelH - CGFloat(row) * (titleH + panelGap)
    return CGRect(x: x, y: y, width: panelW, height: panelH)
}

let panels: [Panel] = [
    Panel(
        title: "Side Strip",
        subtitle: "focused = 78% width, others stack on right",
        originX: panelRect(col: 0, row: 0).minX,
        originY: panelRect(col: 0, row: 0).minY,
        render: { ctx, rect in
            // Focused fills 78% on left
            let mainW = rect.width * 0.78
            let focused = CGRect(x: rect.minX, y: rect.minY, width: mainW, height: rect.height)
            let path = CGPath(roundedRect: focused, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.85))
            ctx.addPath(path); ctx.fillPath()
            // Strip on right
            let stripX = rect.minX + mainW + 4
            let stripW = rect.width - mainW - 4
            let stripCount = 11
            let stripH = rect.height / CGFloat(stripCount) - 2
            for i in 0..<stripCount {
                let y = rect.minY + rect.height - stripH - CGFloat(i) * (stripH + 2)
                let r = CGRect(x: stripX, y: y, width: stripW, height: stripH)
                let p = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0))
                ctx.addPath(p); ctx.fillPath()
            }
        }
    ),
    Panel(
        title: "Full Screen",
        subtitle: "focused fills entire display",
        originX: panelRect(col: 1, row: 0).minX,
        originY: panelRect(col: 1, row: 0).minY,
        render: { ctx, rect in
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.85))
            ctx.addPath(path); ctx.fillPath()
        }
    ),
    Panel(
        title: "Full Column",
        subtitle: "focused expands vertically (1/N width × full height)",
        originX: panelRect(col: 0, row: 1).minX,
        originY: panelRect(col: 0, row: 1).minY,
        render: { ctx, rect in
            // Show 4 columns; second column is focused full-height
            grid(ctx, in: rect, cols: cols, rows: rows, gap: 4, highlight: { _, _ in false })
            // Overlay full-column focused rect
            let cellW = (rect.width - 4 * CGFloat(cols - 1)) / CGFloat(cols)
            let colX = rect.minX + CGFloat(focusedC) * (cellW + 4)
            let focused = CGRect(x: colX, y: rect.minY, width: cellW, height: rect.height)
            let path = CGPath(roundedRect: focused, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(CGColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 0.92))
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(CGColor(red: 0.62, green: 0.42, blue: 0.95, alpha: 1.0))
            ctx.setLineWidth(2.0)
            ctx.addPath(path); ctx.strokePath()
        }
    ),
    Panel(
        title: "Disabled",
        subtitle: "no zoom — static grid only",
        originX: panelRect(col: 1, row: 1).minX,
        originY: panelRect(col: 1, row: 1).minY,
        render: { ctx, rect in
            grid(ctx, in: rect, cols: cols, rows: rows, gap: 4, highlight: { _, _ in false })
        }
    ),
]

for panel in panels {
    let rect = CGRect(x: panel.originX, y: panel.originY, width: panelW, height: panelH)
    panel.render(ctx, rect)
    drawString(panel.title,
        at: CGPoint(x: panel.originX, y: panel.originY + panelH + 14),
        size: 24, color: .white, weight: .bold)
    drawString(panel.subtitle,
        at: CGPoint(x: panel.originX, y: panel.originY + panelH + 38),
        size: 14, color: NSColor(white: 0.55, alpha: 1.0))
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count) bytes)")
