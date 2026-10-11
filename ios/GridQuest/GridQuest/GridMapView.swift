import SwiftUI
import MapKit

struct GridMapView: UIViewRepresentable {
    let tiles: Set<GridTile>
    let squares: [GridSquare]
    let showGrid: Bool
    let frameRequest: Int
    let userLocation: GridPoint?
    let cameraRequest: MapCameraRequest?
    @Binding var selectedTile: GridTile?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        map.accessibilityIdentifier = "explorationMap"
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
                                        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)), animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.tiles != tiles || coordinator.squares != squares {
            coordinator.tiles = tiles
            coordinator.squares = squares
            map.removeOverlays(map.overlays.filter { $0.title != "grid" })
            if !tiles.isEmpty {
                let polygons = tiles.map { Self.polygon($0.corners) }
                let overlay = MKMultiPolygon(polygons)
                overlay.title = "visited"
                map.addOverlay(overlay)
            }
            if let square = squares.first, square.size > 1 {
                let overlay = Self.polygon(square.corners)
                overlay.title = "largest"
                map.addOverlay(overlay)
            }
        }
        coordinator.updateSelection(map)
        if coordinator.frameRequest != frameRequest {
            coordinator.frameRequest = frameRequest
            if !tiles.isEmpty {
                let rect = tiles.reduce(MKMapRect.null) { $0.union(Self.polygon($1.corners).boundingMapRect) }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 140, left: 40, bottom: 240, right: 40), animated: true)
                map.accessibilityValue = "Showing collected squares"
                coordinator.didSetCamera = true
            }
        }
        if let request = cameraRequest, request.id != coordinator.cameraRequestID {
            switch request.target {
            case .home:
                if let userLocation {
                    coordinator.center(map, on: userLocation)
                    coordinator.cameraRequestID = request.id
                    coordinator.didSetCamera = true
                }
            case .largest:
                if let square = squares.first {
                    map.setVisibleMapRect(Self.polygon(square.corners).boundingMapRect,
                                          edgePadding: UIEdgeInsets(top: 140, left: 40, bottom: 240, right: 40), animated: true)
                    map.accessibilityValue = "Showing largest square"
                    coordinator.cameraRequestID = request.id
                    coordinator.didSetCamera = true
                }
            }
        } else if !coordinator.didSetCamera, let userLocation {
            coordinator.center(map, on: userLocation)
            coordinator.didSetCamera = true
        }
        coordinator.updateGrid(map)
    }

    static func polygon(_ points: [GridPoint]) -> MKPolygon {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return MKPolygon(coordinates: coordinates, count: coordinates.count)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: GridMapView
        var tiles = Set<GridTile>()
        var squares: [GridSquare] = []
        var frameRequest = 0
        var cameraRequestID: UUID?
        var didSetCamera = false
        var gridKey: String?
        var highlightedTile: GridTile?
        init(_ parent: GridMapView) { self.parent = parent }

        func updateSelection(_ map: MKMapView) {
            guard highlightedTile != parent.selectedTile ||
                    (parent.selectedTile != nil && !map.overlays.contains(where: { $0.title == "selected" })) else { return }
            map.removeOverlays(map.overlays.filter { $0.title == "selected" })
            highlightedTile = parent.selectedTile
            if let tile = highlightedTile {
                let overlay = GridMapView.polygon(tile.corners)
                overlay.title = "selected"
                map.addOverlay(overlay)
                map.accessibilityValue = parent.tiles.contains(tile) ? "Selected collected square" : "Selected uncollected square"
            } else { map.accessibilityValue = nil }
        }

        func center(_ map: MKMapView, on point: GridPoint) {
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                                            latitudinalMeters: 12_000, longitudinalMeters: 12_000), animated: true)
            map.accessibilityValue = "Showing current location"
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            parent.selectedTile = GridTile(GridPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { updateGrid(mapView) }

        func updateGrid(_ map: MKMapView) {
            let rect = map.visibleMapRect
            let northwest = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
            let southeast = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
            guard parent.showGrid,
                  let a = GridTile(GridPoint(latitude: northwest.latitude, longitude: northwest.longitude)),
                  let b = GridTile(GridPoint(latitude: southeast.latitude, longitude: southeast.longitude)),
                  a.x <= b.x, a.y <= b.y,
                  (b.x - a.x + 1) * (b.y - a.y + 1) <= 900 else {
                if gridKey != nil { map.removeOverlays(map.overlays.filter { $0.title == "grid" }); gridKey = nil }
                return
            }
            let key = "\(a.id)-\(b.id)"
            guard key != gridKey else { return }
            gridKey = key
            map.removeOverlays(map.overlays.filter { $0.title == "grid" })
            var polygons: [MKPolygon] = []
            for x in a.x...b.x { for y in a.y...b.y { polygons.append(GridMapView.polygon(GridTile(x: x, y: y).corners)) } }
            let overlay = MKMultiPolygon(polygons)
            overlay.title = "grid"
            map.insertOverlay(overlay, at: 0)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer: MKOverlayPathRenderer
            if let multi = overlay as? MKMultiPolygon { renderer = MKMultiPolygonRenderer(multiPolygon: multi) }
            else if let polygon = overlay as? MKPolygon { renderer = MKPolygonRenderer(polygon: polygon) }
            else { return MKOverlayRenderer(overlay: overlay) }
            switch overlay.title {
            case "selected":
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.25)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 4
            case "visited":
                renderer.fillColor = UIColor.systemOrange.withAlphaComponent(0.28)
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.9)
                renderer.lineWidth = 1.5
            case "largest":
                renderer.fillColor = UIColor.systemTeal.withAlphaComponent(0.18)
                renderer.strokeColor = .systemTeal
                renderer.lineWidth = 3
            default:
                renderer.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.25)
                renderer.lineWidth = 0.5
            }
            return renderer
        }
    }
}
