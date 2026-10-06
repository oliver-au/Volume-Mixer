import AppKit
import Foundation

// Resize the approved artwork into every standard macOS icon representation.
// Keep the original PNG (and its transparent margins) as the editable source.
let destination = CommandLine.arguments[1]
let sourcePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/Artwork/AppIcon.png"
guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("Missing app icon artwork: \(sourcePath)")
}

try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                       ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                       ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}

// ICNS accepts PNG payloads for these standard and Retina representations.
// Assemble the container directly so packaging doesn't depend on iconutil's
// optional conversion service in the Command Line Tools environment.
func bigEndian(_ value: Int) -> Data {
    var integer = UInt32(value).bigEndian
    return withUnsafeBytes(of: &integer) { Data($0) }
}
var elements = Data()
for (type, name) in [("icp4", "icon_16x16"), ("ic11", "icon_16x16@2x"),
                     ("icp5", "icon_32x32"), ("ic12", "icon_32x32@2x"),
                     ("ic07", "icon_128x128"), ("ic13", "icon_128x128@2x"),
                     ("ic08", "icon_256x256"), ("ic14", "icon_256x256@2x"),
                     ("ic09", "icon_512x512"), ("ic10", "icon_512x512@2x")] {
    let png = try Data(contentsOf: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
    elements.append(Data(type.utf8)); elements.append(bigEndian(png.count + 8)); elements.append(png)
}
var container = Data("icns".utf8)
container.append(bigEndian(elements.count + 8)); container.append(elements)
try container.write(to: URL(fileURLWithPath: destination).deletingPathExtension().appendingPathExtension("icns"))

// Template images share the approved filled-fader silhouette. Export at each
// backing scale rather than relying on runtime downsampling of the large art.
if let menu = NSImage(contentsOfFile: "Resources/Artwork/MenuBarIcon.png") {
    for scale in 1...3 {
        let pixels = 18 * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        menu.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                  operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@\(scale)x"
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: "Resources/MenuBarIcon\(suffix).png"))
    }
} else { fatalError("Missing approved menu-bar artwork") }
