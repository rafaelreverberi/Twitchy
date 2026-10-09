import AppKit
import Foundation
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 14/255, green: 14/255, blue: 16/255, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x:0,y:0,width:1024,height:1024)).fill()
NSColor(calibratedRed: 145/255, green: 70/255, blue: 1, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x:175,y:195,width:674,height:634),xRadius:150,yRadius:150).fill()
NSColor.white.setFill();let triangle=NSBezierPath();triangle.move(to:NSPoint(x:425,y:350));triangle.line(to:NSPoint(x:425,y:674));triangle.line(to:NSPoint(x:680,y:512));triangle.close();triangle.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
