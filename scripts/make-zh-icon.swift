#!/usr/bin/env swift
import AppKit
import Foundation

// Rebuild the icon from the checked-in SVG sources using tools that ship with macOS.
// Run from any directory: swift /path/to/DigUp-ZH/scripts/make-zh-icon.swift
enum IconError: Error { case invalidSource(String), cannotRender(Int), iconutilFailed(Int32) }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let sources = resources.appendingPathComponent("AppIcon")
let fileManager = FileManager.default
let staging = fileManager.temporaryDirectory.appendingPathComponent("DigUp-ZH-Icon-\(UUID().uuidString)")
let iconset = staging.appendingPathComponent("AppIcon.iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: staging) }

func render(_ file: String, size: Int, to destination: URL) throws {
    guard let source = NSImage(contentsOf: sources.appendingPathComponent(file)) else {
        throw IconError.invalidSource(file)
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.cannotRender(size) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
                operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconError.cannotRender(size) }
    try data.write(to: destination, options: .atomic)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try render(pixels <= 32 ? "appicon-small.svg" : "appicon.svg", size: pixels,
                   to: iconset.appendingPathComponent(filename))
    }
}
for size in [32, 256, 1024] {
    try render(size <= 32 ? "appicon-small.svg" : "appicon.svg", size: size,
               to: sources.appendingPathComponent("appicon-\(size).png"))
}
let pack = Process()
pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try pack.run()
pack.waitUntilExit()
guard pack.terminationStatus == 0 else { throw IconError.iconutilFailed(pack.terminationStatus) }
print("Created Resources/AppIcon.icns and 32 / 256 / 1024 px PNG previews.")
