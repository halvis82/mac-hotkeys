import Cocoa

func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// The RGB of the middle pixel, 0 to 255.
func centerPixel(_ image: CGImage) -> [Int] {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
    let bytes = context.data!.bindMemory(to: UInt8.self, capacity: 4)
    return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
}

func thumbnailTests() {
    suite("Thumbnail sizing") {
        let tile = CGSize(width: 600, height: 380) // 300x190 points at 2x

        test("a fullscreen capture shrinks to just cover the tile") {
            let size = Thumbnails.scaledPixelSize(of: CGSize(width: 1512, height: 982), toCover: tile)
            expectEqual(size.width, 600)
            expect(size.height >= 380 && size.height <= 391, "height \(size.height)")
        }

        test("aspect ratio is kept, so the tile crops exactly as before") {
            for source in [CGSize(width: 1512, height: 982), CGSize(width: 600, height: 1400), CGSize(width: 3000, height: 200)] {
                let size = Thumbnails.scaledPixelSize(of: source, toCover: tile)
                let before = source.width / source.height, after = size.width / size.height
                expect(abs(before - after) / before < 0.02, "\(source) became \(size)")
                expect(size.width >= min(tile.width, source.width) && size.height >= min(tile.height, source.height),
                       "\(size) does not cover the tile")
            }
        }

        test("small captures are never enlarged") {
            let small = CGSize(width: 124, height: 98)
            expectEqual(Thumbnails.scaledPixelSize(of: small, toCover: tile), small)
        }

        test("degenerate sizes pass through untouched") {
            expectEqual(Thumbnails.scaledPixelSize(of: .zero, toCover: tile), .zero)
            expectEqual(Thumbnails.scaledPixelSize(of: CGSize(width: 10, height: 10), toCover: .zero), CGSize(width: 10, height: 10))
        }

        test("downscaling produces the planned size and keeps the colors") {
            let source = solidImage(width: 1512, height: 982, red: 0.8, green: 0.2, blue: 0.1)
            let scaled = Thumbnails.downscaled(source, toCover: tile)
            let planned = Thumbnails.scaledPixelSize(of: CGSize(width: 1512, height: 982), toCover: tile)
            expectEqual(scaled.width, Int(planned.width))
            expectEqual(scaled.height, Int(planned.height))
            let a = centerPixel(source), b = centerPixel(scaled)
            expect(zip(a, b).allSatisfy { abs($0 - $1) <= 2 }, "colors moved from \(a) to \(b)")
        }

        test("an image already small enough comes back as is") {
            let source = solidImage(width: 124, height: 98, red: 0, green: 0, blue: 1)
            expect(Thumbnails.downscaled(source, toCover: tile) === source)
        }
    }
}
