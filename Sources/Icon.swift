import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 92, y: 92)
context.scaleBy(x: 0.82, y: 0.82)
let outline = CGPath(roundedRect: CGRect(x: 24, y: 24, width: 976, height: 976), cornerWidth: 220, cornerHeight: 220, transform: nil)
context.addPath(outline); context.clip()
let colors = [CGColor(red: 0.04, green: 0.09, blue: 0.18, alpha: 1), CGColor(red: 0.13, green: 0.25, blue: 0.42, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])
for row in 0..<3 { for col in 0..<3 {
    context.setFillColor(row == 2 && col == 2 ? CGColor(red: 0.35, green: 0.92, blue: 0.79, alpha: 1) : CGColor(gray: 0.96, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 200 + col * 224, y: 200 + row * 224, width: 176, height: 176), cornerWidth: 44, cornerHeight: 44, transform: nil))
    context.fillPath()
} }
let url = URL(fileURLWithPath: CommandLine.arguments.last!)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
