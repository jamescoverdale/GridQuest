import Foundation

nonisolated struct GridPoint: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// Global XYZ tiles, fixed at zoom 14 regardless of the map's display zoom.
nonisolated struct GridTile: Hashable, Codable, Sendable, Identifiable {
    static let zoom = 14
    static let count = 1 << zoom
    let x: Int
    let y: Int
    var id: String { "14/\(x)/\(y)" }

    init(x: Int, y: Int) { self.x = x; self.y = y }

    init?(_ point: GridPoint) {
        guard point.latitude.isFinite, point.longitude.isFinite,
              abs(point.latitude) <= 85.0511287798066 else { return nil }
        let n = Double(Self.count)
        let fraction = n * (point.longitude / 360 + 0.5)
        let wrapped = fraction.truncatingRemainder(dividingBy: n)
        x = Int(floor(wrapped < 0 ? wrapped + n : wrapped))
        let sine = sin(point.latitude * .pi / 180)
        y = min(Self.count - 1, max(0, Int(floor(n * (0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi))))))
    }

    static func longitude(_ x: Int) -> Double { Double(x) / Double(count) * 360 - 180 }
    static func latitude(_ y: Int) -> Double {
        atan(sinh(.pi * (1 - 2 * Double(y) / Double(count)))) * 180 / .pi
    }
    var west: Double { Self.longitude(x) }
    var east: Double { Self.longitude(x + 1) }
    var north: Double { Self.latitude(y) }
    var south: Double { Self.latitude(y + 1) }
    var center: GridPoint { GridPoint(latitude: (north + south) / 2, longitude: (west + east) / 2) }
    var corners: [GridPoint] {
        [GridPoint(latitude: north, longitude: west), GridPoint(latitude: north, longitude: east),
         GridPoint(latitude: south, longitude: east), GridPoint(latitude: south, longitude: west)]
    }
}

nonisolated struct GridSquare: Equatable, Sendable {
    let origin: GridTile
    let size: Int
    var corners: [GridPoint] {
        let west = origin.west, north = origin.north
        let east = GridTile.longitude(origin.x + size), south = GridTile.latitude(origin.y + size)
        return [GridPoint(latitude: north, longitude: west), GridPoint(latitude: north, longitude: east),
                GridPoint(latitude: south, longitude: east), GridPoint(latitude: south, longitude: west)]
    }
}

nonisolated enum TileCalculator {
    static func tiles(along points: [GridPoint]) -> Set<GridTile> {
        var tiles = Set<GridTile>()
        var previous: GridPoint?
        for point in points {
            guard let tile = GridTile(point) else { previous = nil; continue }
            tiles.insert(tile)
            if let previous, abs(previous.longitude - point.longitude) <= 180 {
                tiles.formUnion(crossed(from: previous, to: point))
            }
            previous = point
        }
        return tiles
    }

    /// Segment geometry is in lon/lat, as in Squadra's APK. Sweep columns to
    /// avoid scanning an enormous rectangular area for long diagonal segments.
    static func crossed(from a: GridPoint, to b: GridPoint) -> Set<GridTile> {
        guard let first = GridTile(a), let last = GridTile(b) else { return [] }
        var result: Set<GridTile> = [first, last]
        let minY = min(first.y, last.y), maxY = max(first.y, last.y)
        let delta = b.longitude - a.longitude
        for x in min(first.x, last.x)...max(first.x, last.x) {
            let west = GridTile.longitude(x), east = GridTile.longitude(x + 1)
            let t0 = delta == 0 ? 0 : max(0, min((west - a.longitude) / delta, (east - a.longitude) / delta))
            let t1 = delta == 0 ? 1 : min(1, max((west - a.longitude) / delta, (east - a.longitude) / delta))
            guard t0 <= t1 else { continue }
            let latitude0 = a.latitude + (b.latitude - a.latitude) * t0
            let latitude1 = a.latitude + (b.latitude - a.latitude) * t1
            guard let row0 = GridTile(GridPoint(latitude: latitude0, longitude: a.longitude)),
                  let row1 = GridTile(GridPoint(latitude: latitude1, longitude: a.longitude)) else { continue }
            let low = max(minY, min(row0.y, row1.y) - 1)
            let high = min(maxY, max(row0.y, row1.y) + 1)
            guard low <= high else { continue }
            for y in low...high {
                let tile = GridTile(x: x, y: y)
                if tile == first || tile == last || intersects(a, b, tile: tile) { result.insert(tile) }
            }
        }
        return result
    }

    private static func intersects(_ a: GridPoint, _ b: GridPoint, tile: GridTile) -> Bool {
        let corners = tile.corners
        return (0..<4).contains { intersect(a, b, corners[$0], corners[($0 + 1) % 4]) }
    }

    private static func intersect(_ a: GridPoint, _ b: GridPoint, _ c: GridPoint, _ d: GridPoint) -> Bool {
        let a1 = b.latitude - a.latitude, b1 = a.longitude - b.longitude
        let a2 = d.latitude - c.latitude, b2 = c.longitude - d.longitude
        let determinant = a1 * b2 - a2 * b1
        guard determinant != 0 else { return false }
        let c1 = a1 * a.longitude + b1 * a.latitude
        let c2 = a2 * c.longitude + b2 * c.latitude
        let longitude = (b2 * c1 - b1 * c2) / determinant
        let latitude = (a1 * c2 - a2 * c1) / determinant
        func rounded(_ value: Double) -> Double { (value * 1e9).rounded(.toNearestOrEven) / 1e9 }
        func onSegment(_ p: GridPoint, _ q: GridPoint) -> Bool {
            rounded(longitude) >= rounded(min(p.longitude, q.longitude)) &&
            rounded(longitude) <= rounded(max(p.longitude, q.longitude)) &&
            rounded(latitude) >= rounded(min(p.latitude, q.latitude)) &&
            rounded(latitude) <= rounded(max(p.latitude, q.latitude))
        }
        return onSegment(a, b) && onSegment(c, d)
    }

    /// Sparse dynamic programming: no allocation spanning disconnected continents.
    static func largestSquares(in tiles: Set<GridTile>) -> [GridSquare] {
        var sizes: [GridTile: Int] = [:]
        var largest = 0
        var result: [GridSquare] = []
        for tile in tiles.sorted(by: { $0.y == $1.y ? $0.x > $1.x : $0.y > $1.y }) {
            let size = 1 + min(sizes[GridTile(x: tile.x + 1, y: tile.y)] ?? 0,
                               sizes[GridTile(x: tile.x, y: tile.y + 1)] ?? 0,
                               sizes[GridTile(x: tile.x + 1, y: tile.y + 1)] ?? 0)
            sizes[tile] = size
            if size > largest { largest = size; result.removeAll() }
            if size == largest { result.append(GridSquare(origin: tile, size: size)) }
        }
        return result.sorted { $0.origin.y == $1.origin.y ? $0.origin.x < $1.origin.x : $0.origin.y < $1.origin.y }
    }
}
