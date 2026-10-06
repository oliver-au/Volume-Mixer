import AppKit

enum MenuBarIcon {
    static func image() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for suffix in ["", "@2x", "@3x"] {
            guard let url = Bundle.main.url(forResource: "MenuBarIcon" + suffix, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = image.size
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else {
            return NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Volume Mixer")
        }
        // macOS supplies light, dark and selected colors from the alpha mask.
        image.isTemplate = true
        return image
    }
}
