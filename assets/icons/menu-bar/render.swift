#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Preview assets only. No status item is created and no installed app is touched.
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let glyphWidth: CGFloat = 100
let glyphHeight: CGFloat = 70

func ring(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ weight: CGFloat) {
    let path = NSBezierPath(ovalIn: NSRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2))
    path.lineWidth = weight
    path.stroke()
}

func fang(_ points: [CGFloat]) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: points[0], y: points[1]))
    p.curve(to: NSPoint(x: points[6], y: points[7]),
            controlPoint1: NSPoint(x: points[2], y: points[3]),
            controlPoint2: NSPoint(x: points[4], y: points[5]))
    p.curve(to: NSPoint(x: points[0], y: points[1]),
            controlPoint1: NSPoint(x: points[8], y: points[9]),
            controlPoint2: NSPoint(x: points[10], y: points[11]))
    p.close()
    p.fill()
}

let fangPoints: [[CGFloat]] = [
    [37.0, 30.0, 34.7, 26.6, 40.4, 26.6, 43.4, 38.3, 39.7, 35.8, 37.8, 32.6],
    [45.1, 26.8, 45.0, 22.9, 49.4, 24.0, 48.5, 36.1, 46.7, 32.7, 45.2, 29.2],
    [54.9, 26.8, 54.8, 22.9, 50.6, 24.0, 51.5, 36.1, 53.3, 32.7, 54.8, 29.2],
    [63.0, 30.0, 65.3, 26.6, 59.6, 26.6, 56.6, 38.3, 60.3, 35.8, 62.2, 32.6],
    [37.0, 58.8, 34.7, 62.2, 40.4, 62.2, 43.4, 50.5, 39.7, 53.0, 37.8, 56.2],
    [45.1, 62.0, 45.0, 65.9, 49.4, 64.8, 48.5, 52.7, 46.7, 56.1, 45.2, 59.6],
    [54.9, 62.0, 54.8, 65.9, 50.6, 64.8, 51.5, 52.7, 53.3, 56.1, 54.8, 59.6],
    [63.0, 58.8, 65.3, 62.2, 59.6, 62.2, 56.6, 50.5, 60.3, 53.0, 62.2, 56.2],
]

func drawGlyph(in rect: NSRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: rect.minX, yBy: rect.minY)
    t.scaleX(by: rect.width / glyphWidth, yBy: rect.height / glyphHeight)
    t.concat()
    color.setFill(); color.setStroke()
    let connectors = NSBezierPath()
    connectors.move(to: NSPoint(x: 24.4, y: 24.0))
    connectors.line(to: NSPoint(x: 32.2, y: 29.0))
    connectors.move(to: NSPoint(x: 75.6, y: 24.0))
    connectors.line(to: NSPoint(x: 67.8, y: 29.0))
    connectors.lineWidth = 5.5
    connectors.stroke()
    ring(15, 15, 13, 3.8)
    ring(85, 15, 13, 3.8)
    ring(50, 44.4, 23.5, 3.8)
    for x: CGFloat in [15, 85] {
        NSBezierPath(ovalIn: NSRect(x: x-4.8, y: 10.2, width: 9.6, height: 9.6)).fill()
    }
    for points in fangPoints { fang(points) }
    NSGraphicsContext.restoreGraphicsState()
}

@discardableResult
func png(_ name: String, width: Int, height: Int, scale: Int = 2, draw: () -> Void) throws -> NSImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width*scale, height: height*scale, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height*scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let image = ctx.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    return NSImage(cgImage: image, size: NSSize(width: width, height: height))
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255,
            blue: CGFloat(hex & 255)/255, alpha: 1)
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
    ])
}
func box(_ rect: NSRect, fill: NSColor, radius: CGFloat = 0) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func symbol(_ name: String, in rect: NSRect, tint: NSColor) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    let tinted = NSImage(size: rect.size, flipped: false) { bounds in
        symbol.draw(in: bounds)
        tint.setFill(); bounds.fill(using: .sourceIn)
        return true
    }
    tinted.draw(in: rect)
}

try png("khuluma-menu-template.png", width: 28, height: 20, scale: 1) {
    drawGlyph(in: NSRect(x: 1.143, y: 1, width: 25.714, height: 18), color: .black)
}
let retina = try png("khuluma-menu-template@2x.png", width: 28, height: 20, scale: 2) {
    drawGlyph(in: NSRect(x: 1.143, y: 1, width: 25.714, height: 18), color: .black)
}
retina.isTemplate = true

let pdfURL = output.appendingPathComponent("khuluma-menu-template.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 28, height: 20)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 20); pdf.scaleBy(x: 1, y: -1)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
drawGlyph(in: NSRect(x: 1.143, y: 1, width: 25.714, height: 18), color: .black)
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage(); pdf.closePDF()

let fangSVG = fangPoints.map { p in
    "<path d=\"M \(p[0]) \(p[1]) C \(p[2]) \(p[3]) \(p[4]) \(p[5]) \(p[6]) \(p[7]) C \(p[8]) \(p[9]) \(p[10]) \(p[11]) \(p[0]) \(p[1]) Z\"/>"
}.joined(separator: "\n    ")
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="28" height="20" viewBox="0 0 28 20">
  <title>Khuluma menu bar template glyph — preview</title>
  <g transform="translate(1.143 1) scale(0.25714)" fill="#000">
    <path d="M24.4 24 32.2 29 M75.6 24 67.8 29" fill="none" stroke="#000" stroke-width="5.5"/>
    <g fill="none" stroke="#000" stroke-width="3.8">
      <circle cx="15" cy="15" r="13"/><circle cx="85" cy="15" r="13"/>
      <circle cx="50" cy="44.4" r="23.5"/>
    </g>
    <circle cx="15" cy="15" r="4.8"/><circle cx="85" cy="15" r="4.8"/>
    \(fangSVG)
  </g>
</svg>
"""
try svg.write(to: output.appendingPathComponent("khuluma-menu-template.svg"), atomically: true, encoding: .utf8)

try png("menu-bar-preview.png", width: 720, height: 500) {
    box(NSRect(x: 0, y: 0, width: 720, height: 500), fill: color(0xF3F1EC))
    text("Khuluma · menu bar idea", x: 30, y: 24, size: 24, weight: .semibold, color: color(0x222320))
    text("Template glyph preview · 24 pt menu bars rendered at 2× Retina", x: 30, y: 58, size: 12, color: color(0x62645F))
    let rows: [(CGFloat, String, UInt32, UInt32, Bool)] = [
        (94, "Light", 0xE5E5E3, 0x252624, false),
        (166, "Dark", 0x26282C, 0xF1F2F2, false),
        (238, "Selected", 0x26282C, 0xF1F2F2, true),
    ]
    for (y, label, bg, fg, selected) in rows {
        text(label, x: 30, y: y, size: 12, weight: .semibold, color: color(0x444640))
        text("16 pt", x: 397, y: y, size: 10, color: color(0x71736F))
        text("18 pt", x: 449, y: y, size: 10, color: color(0x71736F))
        let barY = y + 22
        box(NSRect(x: 30, y: barY, width: 660, height: 24), fill: color(bg), radius: 5)
        text("Finder", x: 42, y: barY+4, size: 11, weight: .semibold, color: color(fg))
        text("File    Edit    View    Go", x: 88, y: barY+4, size: 11, color: color(fg))
        if selected {
            box(NSRect(x: 446, y: barY+1, width: 34, height: 22), fill: color(0x585B60), radius: 4)
        }
        drawGlyph(in: NSRect(x: 396, y: barY+4, width: 22.857, height: 16), color: color(fg))
        drawGlyph(in: NSRect(x: 450, y: barY+3, width: 25.714, height: 18), color: color(fg))
        symbol("wifi", in: NSRect(x: 504, y: barY+5, width: 16, height: 13), tint: color(fg))
        symbol("battery.75percent", in: NSRect(x: 534, y: barY+5, width: 24, height: 13), tint: color(fg))
        text("Fri 23 Oct  14:24", x: 580, y: barY+4, size: 10.5, color: color(fg))
    }
    text("18 pt detail", x: 30, y: 329, size: 13, weight: .semibold, color: color(0x444640))
    text("Black and clear only. macOS supplies the light, dark and selected tint.", x: 30, y: 350, size: 11, color: color(0x62645F))
    box(NSRect(x: 30, y: 378, width: 316, height: 80), fill: .white, radius: 9)
    box(NSRect(x: 360, y: 378, width: 330, height: 80), fill: color(0x26282C), radius: 9)
    drawGlyph(in: NSRect(x: 140, y: 387, width: 87.142, height: 61), color: color(0x252624))
    drawGlyph(in: NSRect(x: 475, y: 387, width: 87.142, height: 61), color: color(0xF1F2F2))
    text("Illustrated menu bars · preview only · current app is unchanged", x: 30, y: 477, size: 10, color: color(0x71736F))
}

print("Wrote SVG, vector PDF, transparent 1×/2× PNGs and a 2× Retina preview to \(output.path)")
