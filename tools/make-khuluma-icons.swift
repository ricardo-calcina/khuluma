#!/usr/bin/env swift
// Re-export the approved raised artwork with a clean native icon canvas.
// Run: CLANG_MODULE_CACHE_PATH=/private/tmp/khuluma-icon-cache xcrun swift
//   -module-cache-path /private/tmp/khuluma-icon-cache tools/make-khuluma-icons.swift
// This does not build, install, register, or restart Khuluma.
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error { case invalid(String) }

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("assets/icons/app", isDirectory: true)

func readImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconError.invalid("Cannot read \(url.path)")
    }
    return image
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError.invalid("Cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.invalid("Cannot finish \(url.path)") }
}

func renderedIcon(_ source: CGImage, size: Int) throws -> CGImage {
    guard source.width == 1254, source.height == 1254 else {
        throw IconError.invalid("Approved artwork must remain 1254 × 1254")
    }
    // These identical source coordinates preserve both approved compositions.
    // Clip a few pixels inside the material edge to remove the presentation
    // background and its external shadow without fringe-colour estimation.
    let crop = CGRect(x: 94, y: 92, width: 1066, height: 1048)
    guard let tile = source.cropping(to: crop) else { throw IconError.invalid("Artwork crop failed") }
    let c = context(size, size)
    let side = CGFloat(size) * 824 / 1024
    let inset = (CGFloat(size) - side) / 2
    let tileRect = CGRect(x: inset, y: inset, width: side, height: side)
    c.interpolationQuality = .high
    c.addPath(CGPath(roundedRect: tileRect, cornerWidth: side * 0.245,
                     cornerHeight: side * 0.245, transform: nil))
    c.clip()
    c.draw(tile, in: tileRect)
    return c.makeImage()!
}

func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

func records(_ container: Data) throws -> [(Data, Data)] {
    guard container.count >= 8, container.prefix(4) == Data("icns".utf8) else {
        throw IconError.invalid("Invalid ICNS header")
    }
    func integer(_ offset: Int) -> Int {
        container[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    guard integer(4) == container.count else { throw IconError.invalid("ICNS length mismatch") }
    var offset = 8
    var result: [(Data, Data)] = []
    while offset < container.count {
        guard offset + 8 <= container.count else { throw IconError.invalid("Truncated ICNS record") }
        let length = integer(offset + 4)
        guard length >= 8, offset + length <= container.count else { throw IconError.invalid("Invalid ICNS record length") }
        result.append((Data(container[offset..<(offset + 4)]), Data(container[offset..<(offset + length)])))
        offset += length
    }
    return result
}

func adaptiveContainer(light: Data, dark: Data) throws -> Data {
    // Native ICNS nested-dark record. The nested container omits its own outer
    // 8-byte header. See icnsutil's IcnsFile.add_media / write implementation:
    // https://github.com/relikd/icnsutil/blob/main/icnsutil/IcnsFile.py
    // Standard readers retain the ordinary light representations as fallback.
    let darkType = Data([0xFD, 0xD9, 0x2F, 0xA8])
    _ = try records(dark)
    var body = Data()
    for (type, record) in try records(light) where type != Data("TOC ".utf8) && type != darkType {
        body.append(record)
    }
    body.append(darkType)
    body.append(bigEndian(UInt32(dark.count)))
    body.append(dark.dropFirst(8))
    var result = Data("icns".utf8)
    result.append(bigEndian(UInt32(body.count + 8)))
    result.append(body)
    _ = try records(result)
    return result
}

func convertIconset(_ directory: URL, to destination: URL) throws {
    // PNG-backed records preserve full alpha at every standard macOS size.
    // Writing the container directly also works in restricted build sandboxes
    // where iconutil cannot load the CoreUI export service.
    let representations = [
        ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png")
    ]
    var body = Data()
    for (type, filename) in representations {
        let png = try Data(contentsOf: directory.appendingPathComponent(filename))
        body.append(Data(type.utf8))
        body.append(bigEndian(UInt32(png.count + 8)))
        body.append(png)
    }
    var container = Data("icns".utf8)
    container.append(bigEndian(UInt32(body.count + 8)))
    container.append(body)
    try container.write(to: destination)
}

func drawLabel(_ string: String, at point: CGPoint, color: NSColor, fontSize: CGFloat = 16) {
    (string as NSString).draw(at: point, withAttributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color
    ])
}

func preview(_ images: [CGImage], to url: URL) throws {
    let width = 1440, height = 860
    let c = context(width, height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    for (column, background) in [NSColor(calibratedWhite: 0.94, alpha: 1), NSColor(calibratedWhite: 0.10, alpha: 1)].enumerated() {
        background.setFill()
        NSRect(x: column * 720, y: 0, width: 720, height: height).fill()
        let foreground: NSColor = column == 0 ? .black : .white
        drawLabel(column == 0 ? "Light background" : "Dark background", at: CGPoint(x: column * 720 + 28, y: 812), color: foreground, fontSize: 22)
        for (row, image) in images.enumerated() {
            let y = 450 - row * 350
            c.draw(image, in: CGRect(x: column * 720 + 28, y: y, width: 320, height: 320))
            drawLabel(row == 0 ? "Light icon" : "Dark icon", at: CGPoint(x: column * 720 + 356, y: y + 270), color: foreground)
            for (index, size) in [16, 32, 64, 128].enumerated() {
                let x = column * 720 + 356 + (index % 2) * 150
                let sy = y + 130 - (index / 2) * 150
                c.draw(image, in: CGRect(x: x, y: sy, width: size, height: size))
                drawLabel("\(size) px", at: CGPoint(x: x, y: sy - 26), color: foreground, fontSize: 13)
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try writePNG(c.makeImage()!, to: url)
}

func export() throws {
    let temporary = fm.temporaryDirectory.appendingPathComponent("khuluma-icon-export-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    var fullSize: [CGImage] = []
    for appearance in ["Light", "Dark"] {
        let source = try readImage(output.appendingPathComponent("raised-\(appearance.lowercased())-preview.png"))
        let iconset = temporary.appendingPathComponent("Khuluma-\(appearance).iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let image = try renderedIcon(source, size: size * scale)
                let suffix = scale == 2 ? "@2x" : ""
                try writePNG(image, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        let image = try renderedIcon(source, size: 1024)
        fullSize.append(image)
        try writePNG(image, to: output.appendingPathComponent("Khuluma-\(appearance).png"))
        try convertIconset(iconset, to: output.appendingPathComponent("Khuluma-\(appearance).icns"))
    }
    let light = try Data(contentsOf: output.appendingPathComponent("Khuluma-Light.icns"))
    let dark = try Data(contentsOf: output.appendingPathComponent("Khuluma-Dark.icns"))
    try adaptiveContainer(light: light, dark: dark).write(to: output.appendingPathComponent("Khuluma.icns"))
    try preview(fullSize, to: output.appendingPathComponent("export-preview.png"))
    print("Exported light/dark PNG and ICNS, with a nested dark variant in Khuluma.icns.")
    print("The ordinary light fallback is independent of system dark-icon support.")
    print("Intermediate iconsets retained at \(temporary.path)")
}

// Public API probe: changes only this process's appearance and writes raster
// evidence to a caller-provided directory. Use cross-app controls to detect an
// IconServices placeholder rather than mistaking it for successful resolution.
func probe(_ paths: [String], into directory: URL) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let application = NSApplication.shared
    for (index, path) in paths.enumerated() {
        var rendered: [Data] = []
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            application.appearance = appearance
            var result: CGImage?
            appearance.performAsCurrentDrawingAppearance {
                let image = NSWorkspace.shared.icon(forFile: path)
                let c = context(256, 256)
                var proposed = NSRect(x: 0, y: 0, width: 256, height: 256)
                if let raster = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
                    c.draw(raster, in: CGRect(x: 0, y: 0, width: 256, height: 256))
                }
                result = c.makeImage()
            }
            let destination = directory.appendingPathComponent("\(index)-\(name).png")
            try writePNG(result!, to: destination)
            rendered.append(try Data(contentsOf: destination))
        }
        print("\(path): light and dark rasters \(rendered[0] == rendered[1] ? "IDENTICAL" : "DIFFER")")
    }
    print("Inspect \(directory.path); identical control apps means the probe is inconclusive.")
}

do {
    if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--probe" {
        try probe(Array(CommandLine.arguments.dropFirst(3)), into: URL(fileURLWithPath: CommandLine.arguments[2]))
    } else if CommandLine.arguments.count == 1 {
        try export()
    } else {
        throw IconError.invalid("Usage: make-khuluma-icons.swift [--probe OUTPUT_DIR APP_PATH ...]")
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
