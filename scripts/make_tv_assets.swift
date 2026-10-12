import AppKit
import Foundation

// Native layered tvOS assets from the supplied Icon Composer foreground.
// Usage: swift scripts/make_tv_assets.swift Apps/tvOS/Assets.xcassets/TVBrand.brandassets
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.icon/Assets/Twitchy_Logo_Vector_White.svg")
guard let logo = NSImage(contentsOf: source) else { fatalError("Missing logo: \(source.path)") }
func json(_ value: [String: Any], _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
let info: [String: Any] = ["author": "xcode", "version": 1]
func draw(_ width: Int, _ height: Int, _ layer: String, _ path: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let w = CGFloat(width), h = CGFloat(height)
    if layer != "Front" {
        // Match the Icon Composer's Display P3 purple; the back remains opaque.
        NSColor(displayP3Red: 0.49585, green: 0.24915, blue: 0.94727, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()
    }
    if layer != "Back" {
        // Keep the mark inside the focus/parallax safe area with generous margins.
        let edge = h * 0.90
        logo.draw(in: NSRect(x: (w - edge) / 2, y: (h - edge) / 2, width: edge, height: edge),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: path)
}
var assets: [[String: Any]] = []
for (name, width, height) in [("App Icon", 400, 240), ("App Store Icon", 1280, 768)] {
    let stack = root.appendingPathComponent(name + ".imagestack")
    try json(["layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]], "info": info], stack.appendingPathComponent("Contents.json"))
    for layer in ["Front", "Back"] {
        let set = stack.appendingPathComponent(layer + ".imagestacklayer/Content.imageset")
        var images: [[String: String]] = []
        for scale in 1...2 {
            let filename = "\(layer)-\(scale)x.png"
            try fm.createDirectory(at: set, withIntermediateDirectories: true)
            try draw(width * scale, height * scale, layer, set.appendingPathComponent(filename))
            images.append(["idiom": "tv", "scale": "\(scale)x", "filename": filename])
        }
        try json(["images": images, "info": info], set.appendingPathComponent("Contents.json"))
    }
    assets.append(["filename": name + ".imagestack", "idiom": "tv", "size": "\(width)x\(height)", "role": "primary-app-icon"])
}
for (name, width, role) in [("Top Shelf", 1920, "top-shelf-image"), ("Top Shelf Wide", 2320, "top-shelf-image-wide")] {
    let set = root.appendingPathComponent(name + ".imageset")
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    try draw(width, 720, "Shelf", set.appendingPathComponent("shelf.png"))
    try json(["images": [["idiom": "tv", "scale": "1x", "filename": "shelf.png"]], "info": info], set.appendingPathComponent("Contents.json"))
    assets.append(["filename": name + ".imageset", "idiom": "tv", "size": "\(width)x720", "role": role])
}
try json(["assets": assets, "info": info], root.appendingPathComponent("Contents.json"))
