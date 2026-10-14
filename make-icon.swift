// Рисует иконку приложения (щит на скруглённом фоне) в PNG нужного размера: swift make-icon.swift <out.png> <size>
import AppKit
let out = CommandLine.arguments[1], px = CGFloat(Double(CommandLine.arguments[2])!)
let img = NSImage(size: NSSize(width: px, height: px))
img.lockFocus()
let r = NSRect(x: px*0.06, y: px*0.06, width: px*0.88, height: px*0.88)
let bg = NSBezierPath(roundedRect: r, xRadius: px*0.2, yRadius: px*0.2)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.70, alpha: 1))!.draw(in: bg, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: px*0.5, weight: .semibold)
if let s = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let t = NSImage(size: s.size); t.lockFocus()
    s.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set(); NSRect(origin: .zero, size: s.size).fill(using: .sourceAtop); t.unlockFocus()
    t.draw(at: NSPoint(x: (px - t.size.width)/2, y: (px - t.size.height)/2), from: .zero, operation: .sourceOver, fraction: 1)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
