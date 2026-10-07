import Foundation

public enum RasterOperations {
    public static func selection(width: Int, height: Int, polygon: [PaintPoint]) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return mask }
        let lowY = max(0, Int(floor(max(-Double(height), polygon.map(\.y).min()!))))
        let highY = min(height - 1, Int(ceil(min(Double(height), polygon.map(\.y).max()!))))
        guard lowY <= highY else { return mask }
        for y in lowY...highY {
            let scanY = Double(y) + 0.5
            var crossings: [Double] = []
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                if (a.y > scanY) != (b.y > scanY) {
                    crossings.append(a.x + (scanY - a.y) * (b.x - a.x) / (b.y - a.y))
                }
            }
            crossings.sort()
            for i in stride(from: 0, to: crossings.count - 1, by: 2) {
                let start = max(0, Int(ceil(max(-Double(width), crossings[i] - 0.5))))
                let end = min(width - 1, Int(floor(min(Double(width), crossings[i + 1] - 0.5))))
                if start <= end { for x in start...end { mask[y * width + x] = 255 } }
            }
        }
        return mask
    }

    /// Connected four-neighbour fill. Selection is both a boundary and an edit mask.
    public static func floodFill(pixels: inout [UInt8], width: Int, height: Int, x: Int, y: Int,
                                 color: PaintColor, tolerance: Int, mask: [UInt8]?, alphaLocked: Bool) {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              (0..<width).contains(x), (0..<height).contains(y),
              mask == nil || mask?.count == width * height else { return }
        let seed = y * width + x
        if let mask, mask[seed] == 0 { return }
        let target = Array(pixels[seed * 4..<seed * 4 + 4])
        let replacement = color.premultipliedBytes
        let threshold = min(255, max(0, tolerance))
        var visited = [UInt8](repeating: 0, count: width * height)
        var queue = [seed]; visited[seed] = 1
        var head = 0
        while head < queue.count {
            let index = queue[head]; head += 1
            if let mask, mask[index] == 0 { continue }
            let offset = index * 4
            guard (0..<4).allSatisfy({ abs(Int(pixels[offset + $0]) - Int(target[$0])) <= threshold }) else { continue }
            if alphaLocked {
                let alpha = Double(pixels[offset + 3]) / 255
                let values = PaintColor(color.red, color.green, color.blue, alpha).premultipliedBytes
                for c in 0..<4 { pixels[offset + c] = values[c] }
            } else { for c in 0..<4 { pixels[offset + c] = replacement[c] } }
            let px = index % width, py = index / width
            let neighbors = [px > 0 ? index - 1 : -1, px + 1 < width ? index + 1 : -1,
                             py > 0 ? index - width : -1, py + 1 < height ? index + width : -1]
            for n in neighbors where n >= 0 && visited[n] == 0 { visited[n] = 1; queue.append(n) }
        }
    }

    /// Destructive selected-pixel transform, nearest neighbour, with source-over compositing.
    public static func transform(pixels: [UInt8], mask: [UInt8], width: Int, height: Int,
                                 translation: PaintPoint, scale: Double, angle: Double) -> (pixels: [UInt8], mask: [UInt8]) {
        guard pixels.count == width * height * 4, mask.count == width * height,
              scale.isFinite && (0.1...4).contains(scale), angle.isFinite,
              translation.x.isFinite, translation.y.isFinite else { return (pixels, mask) }
        let selected = mask.indices.filter { mask[$0] != 0 }
        guard !selected.isEmpty else { return (pixels, mask) }
        let minX = selected.map { $0 % width }.min()!, maxX = selected.map { $0 % width }.max()!
        let minY = selected.map { $0 / width }.min()!, maxY = selected.map { $0 / width }.max()!
        let cx = Double(minX + maxX + 1) / 2, cy = Double(minY + maxY + 1) / 2
        var output = pixels, resultMask = [UInt8](repeating: 0, count: width * height)
        for index in selected { for c in 0..<4 { output[index * 4 + c] = 0 } }
        let cosine = cos(angle), sine = sin(angle)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - cx - translation.x
                let dy = Double(y) + 0.5 - cy - translation.y
                let sx = Int(floor((dx * cosine + dy * sine) / scale + cx))
                let sy = Int(floor((-dx * sine + dy * cosine) / scale + cy))
                guard (0..<width).contains(sx), (0..<height).contains(sy), mask[sy * width + sx] != 0 else { continue }
                let src = (sy * width + sx) * 4, dest = (y * width + x) * 4
                let inverse = 255 - Int(pixels[src + 3])
                for c in 0..<4 {
                    output[dest + c] = UInt8(min(255, Int(pixels[src + c]) + (Int(output[dest + c]) * inverse + 127) / 255))
                }
                resultMask[y * width + x] = 255
            }
        }
        return (output, resultMask)
    }
}
