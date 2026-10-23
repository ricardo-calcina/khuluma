#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Vector assets and previews only. Reads Ready unchanged; never builds or installs an app.
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let readyPDF = NSImage(contentsOf: output.deletingLastPathComponent().appendingPathComponent("khuluma-menu-template.pdf"))!

enum Glyph: String, CaseIterable {
    case ready, speaking, sealing, emblemSpeaking = "emblem-speaking", emblemSealing = "emblem-sealing"
    case emblemFrame = "emblem-frame", emblemRotor = "emblem-rotor"
}
let productionOnly = CommandLine.arguments.dropFirst() == ["--production"]
guard CommandLine.arguments.count == 1 || productionOnly else {
    fputs("Usage: render.swift [--production]\n",stderr); exit(2)
}

func line(_ points: [NSPoint], width: CGFloat = 1.3) {
    let p = NSBezierPath(); p.move(to: points[0])
    for point in points.dropFirst() { p.line(to: point) }
    p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
}
func triangle(_ points: [NSPoint], into path: NSBezierPath? = nil) {
    let p = path ?? NSBezierPath(); p.move(to: points[0])
    for point in points.dropFirst() { p.line(to: point) }
    p.close(); if path == nil { p.fill() }
}
func ellipse(_ rect: NSRect, width: CGFloat) {
    let p = NSBezierPath(ovalIn: rect); p.lineWidth = width; p.stroke()
}
func curve(_ start: NSPoint, _ end: NSPoint, _ c1: NSPoint, _ c2: NSPoint, width: CGFloat = 1.25) {
    let p = NSBezierPath(); p.move(to: start); p.curve(to: end, controlPoint1: c1, controlPoint2: c2)
    p.lineWidth = width; p.lineCapStyle = .round; p.stroke()
}
func teeth() {
    triangle([.init(x: 10.9,y: 4.5),.init(x: 12.5,y: 4.1),.init(x: 13.1,y: 8.2)])
    triangle([.init(x: 15.5,y: 4.1),.init(x: 17.1,y: 4.5),.init(x: 14.9,y: 8.2)])
    triangle([.init(x: 10.9,y: 15.5),.init(x: 12.5,y: 15.9),.init(x: 13.1,y: 11.8)])
    triangle([.init(x: 15.5,y: 15.9),.init(x: 17.1,y: 15.5),.init(x: 14.9,y: 11.8)])
}
func seal() {
    for start in [-160.0, 20.0] {
        let points = (0...56).map { index -> NSPoint in
            let a = (start + Double(index) * 140 / 56) * .pi / 180
            return NSPoint(x: 14 + 7.8 * cos(a), y: 10 + 7.8 * sin(a))
        }
        line(points, width: 1.5)
    }
    triangle([.init(x: 21.8,y: 9.2),.init(x: 18.1,y: 6.8),.init(x: 22.4,y: 5.2)])
    triangle([.init(x: 6.2,y: 10.8),.init(x: 9.9,y: 13.2),.init(x: 5.6,y: 14.8)])
    teeth()
}
func emblemFrameArtwork() {
    line([.init(x: 24.4,y: 24),.init(x: 32.2,y: 29)],width: 5.5)
    line([.init(x: 75.6,y: 24),.init(x: 67.8,y: 29)],width: 5.5)
    for x: CGFloat in [15,85] {
        ellipse(.init(x: x-13,y: 2,width: 26,height: 26),width: 3.8)
        NSBezierPath(ovalIn: .init(x: x-4.8,y: 10.2,width: 9.6,height: 9.6)).fill()
    }
}
func emblemTransform(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: 1.143,yBy: 1); t.scale(by: 0.25714); t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}
func emblemRotorArtwork() {
    let inner = NSAffineTransform(); inner.translateX(by: 10.8,yBy: 16.4); inner.scale(by: 2.8); inner.concat()
    seal()
}
func emblem(_ speaking: Bool) {
    emblemTransform {
        emblemFrameArtwork()
        if speaking {
            let mouth = NSBezierPath(ovalIn: .init(x: 26.5,y: 20.9,width: 47,height: 47))
            mouth.windingRule = .evenOdd
            triangle([.init(x: 36,y: 29),.init(x: 42,y: 26),.init(x: 45,y: 40)],into: mouth)
            triangle([.init(x: 58,y: 26),.init(x: 64,y: 29),.init(x: 55,y: 40)],into: mouth)
            triangle([.init(x: 36,y: 59.8),.init(x: 42,y: 62.8),.init(x: 45,y: 48.8)],into: mouth)
            triangle([.init(x: 58,y: 62.8),.init(x: 64,y: 59.8),.init(x: 55,y: 48.8)],into: mouth)
            mouth.fill()
        } else {
            emblemRotorArtwork()
        }
    }
}
func artwork(_ glyph: Glyph) {
    switch glyph {
    case .ready: readyPDF.draw(in: .init(x: 0,y: 0,width: 28,height: 20))
    case .speaking:
        ellipse(.init(x: 6.75,y: 2.75,width: 14.5,height: 14.5),width: 1.3)
        teeth()
        for reflect in [false,true] {
            NSGraphicsContext.saveGraphicsState()
            if reflect { let t = NSAffineTransform(); t.translateX(by: 28,yBy: 0); t.scaleX(by: -1,yBy: 1); t.concat() }
            curve(.init(x: 6,y: 6),.init(x: 6,y: 14),.init(x: 3.8,y: 7.3),.init(x: 3.8,y: 12.7))
            curve(.init(x: 3.2,y: 4),.init(x: 3.2,y: 16),.init(x: 0.2,y: 7),.init(x: 0.2,y: 13))
            NSGraphicsContext.restoreGraphicsState()
        }
    case .sealing: seal()
    case .emblemSpeaking: emblem(true)
    case .emblemSealing: emblem(false)
    case .emblemFrame: emblemTransform { emblemFrameArtwork() }
    case .emblemRotor: emblemTransform { emblemRotorArtwork() }
    }
}
func drawGlyph(_ glyph: Glyph, in rect: NSRect, tint: NSColor) {
    // Isolate tinting so clear fang cutouts remain transparent in both themes.
    let image = NSImage(size: .init(width: 28,height: 20),flipped: true) { bounds in
        NSColor.black.set(); artwork(glyph)
        tint.setFill(); bounds.fill(using: .sourceIn)
        return true
    }
    image.draw(in: rect)
}
func png(_ name: String, width: Int, height: Int, scale: Int = 2, draw: () -> Void) throws {
    let ctx = CGContext(data: nil,width: width*scale,height: height*scale,bitsPerComponent: 8,
                        bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0,y: CGFloat(height*scale)); ctx.scaleBy(x: CGFloat(scale),y: -CGFloat(scale))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx,flipped: true)
    draw(); NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try bitmap.representation(using: .png,properties: [:])!.write(to: output.appendingPathComponent(name))
}
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex>>16)&255)/255,green: CGFloat((hex>>8)&255)/255,blue: CGFloat(hex&255)/255,alpha: 1)
}
func box(_ rect: NSRect, _ hex: UInt32, radius: CGFloat = 0) {
    color(hex).setFill(); NSBezierPath(roundedRect: rect,xRadius: radius,yRadius: radius).fill()
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, weight: NSFont.Weight = .regular, hex: UInt32 = 0x20211F) {
    (value as NSString).draw(at: .init(x: x,y: y),withAttributes: [.font: NSFont.systemFont(ofSize: size,weight: weight),.foregroundColor: color(hex)])
}
func centered(_ value: String, _ cx: CGFloat, _ y: CGFloat, _ size: CGFloat, weight: NSFont.Weight = .regular, hex: UInt32 = 0x20211F) {
    let width = (value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size,weight: weight)]).width
    text(value,cx-width/2,y,size,weight: weight,hex: hex)
}

// --production leaves the approved Ready, Finishing and full-emblem references
// byte-identical while refreshing the corrected Recording and animation layers.
let exportGlyphs: [Glyph] = productionOnly ? [.speaking,.emblemFrame,.emblemRotor] : Glyph.allCases.filter { $0 != .ready }
for glyph in exportGlyphs {
    for scale in [1,2] {
        try png(glyph.rawValue + (scale == 2 ? "@2x" : "") + ".png",width: 28,height: 20,scale: scale) {
            drawGlyph(glyph,in: .init(x: 0,y: 0,width: 28,height: 20),tint: .black)
        }
    }
    var media = CGRect(x: 0,y: 0,width: 28,height: 20)
    let pdf = CGContext(output.appendingPathComponent(glyph.rawValue+".pdf") as CFURL,mediaBox: &media,nil)!
    pdf.beginPDFPage(nil); pdf.translateBy(x: 0,y: 20); pdf.scaleBy(x: 1,y: -1)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf,flipped: true)
    NSColor.black.set(); artwork(glyph)
    NSGraphicsContext.restoreGraphicsState(); pdf.endPDFPage(); pdf.closePDF()
}

let productionAssets = output.deletingLastPathComponent()
for (source,destination) in [
    ("speaking.pdf","khuluma-recording-template.pdf"),
    ("emblem-speaking.pdf","khuluma-emblem-recording-template.pdf"),
    ("emblem-sealing.pdf","khuluma-emblem-finishing-template.pdf"),
    ("emblem-frame.pdf","khuluma-emblem-frame-template.pdf"),
    ("emblem-rotor.pdf","khuluma-emblem-rotor-template.pdf")
] {
    try Data(contentsOf: output.appendingPathComponent(source)).write(to: productionAssets.appendingPathComponent(destination))
}

try png("status-options.png",width: 780,height: 850) {
    box(.init(x: 0,y: 0,width: 780,height: 850),0xF5F3EE)
    text("Khuluma · cursed speech",34,25,26,weight: .semibold)
    text("Two options for the same three states. Ready keeps your current emblem.",34,64,13,hex: 0x67685F)
    let xs: [CGFloat] = [150,390,630]
    for (i,title) in ["READY","RECORDING","FINISHING"].enumerated() {
        centered(title,xs[i],109,10,weight: .semibold,hex: 0x686B62)
    }
    let sets: [(CGFloat,String,[Glyph],[String])] = [
        (148,"1. Speaking mouth → turning seal",[.ready,.speaking,.sealing],["Current emblem","Mouth + voice strokes","Turning fang seal"]),
        (438,"2. Keep the full emblem",[.ready,.emblemSpeaking,.emblemSealing],["Current emblem","Dark, open mouth","Turning centre"])
    ]
    for (top,title,glyphs,captions) in sets {
        text(title,34,top,17,weight: .semibold)
        for i in 0...2 {
            drawGlyph(glyphs[i],in: .init(x: xs[i]-56,y: top+44,width: 112,height: 80),tint: color(0x20211F))
            centered(captions[i],xs[i],top+145,11,hex: 0x67685F)
        }
        text("18 pt",34,top+182,10,weight: .medium,hex: 0x67685F)
        for (index,bg,fg) in [(0,UInt32(0xE4E5E1),UInt32(0x20211F)),(1,UInt32(0x252724),UInt32(0xF4F4EF))] {
            let y = top+180+CGFloat(index)*34
            box(.init(x: 94,y: y,width: 652,height: 24),bg,radius: 4)
            for i in 0...2 {
                drawGlyph(glyphs[i],in: .init(x: xs[i]-14,y: y+2,width: 28,height: 20),tint: color(fg))
            }
        }
    }
    box(.init(x: 34,y: 707,width: 712,height: 1),0xD8D9D1)
    text("Ready  →  Recording  →  Finishing  →  Ready",34,732,15,weight: .medium)
    text("Finishing covers transcription, paste and Enter for the take.",34,759,12,hex: 0x67685F)
    text("Vector concepts · light/dark 18 pt previews at 2× Retina · no animation shown",34,798,10,hex: 0x67685F)
    text("Preview only · the installed app is unchanged",34,816,10,hex: 0x67685F)
}
print("Wrote \(exportGlyphs.count) vector PDF concepts, 1×/2× PNGs, production copies and status-options.png to \(output.path)")
