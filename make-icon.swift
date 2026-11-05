// Gera o ícone do app (1024px): fundo verde-azulado com martelo e PC
import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let sombra = NSShadow(); sombra.shadowBlurRadius = 30; sombra.shadowOffset = NSSize(width: 0, height: -12)
sombra.shadowColor = NSColor.black.withAlphaComponent(0.35); sombra.set()
NSGradient(colors: [NSColor(red: 0.13, green: 0.62, blue: 0.56, alpha: 1),
                    NSColor(red: 0.05, green: 0.20, blue: 0.28, alpha: 1)])!.draw(in: path, angle: -70)
NSGraphicsContext.current?.restoreGraphicsState()
func simbolo(_ nome: String, _ tam: CGFloat, _ peso: NSFont.Weight, _ cor: NSColor, _ c: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: tam, weight: peso)
        .applying(.init(paletteColors: [cor]))
    guard let s = NSImage(systemSymbolName: nome, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    s.draw(in: NSRect(x: c.x - s.size.width / 2, y: c.y - s.size.height / 2, width: s.size.width, height: s.size.height))
}
simbolo("desktopcomputer", 400, .regular, NSColor.white.withAlphaComponent(0.95), NSPoint(x: 512, y: 540))
simbolo("hammer.fill", 210, .bold, NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), NSPoint(x: 690, y: 330))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
