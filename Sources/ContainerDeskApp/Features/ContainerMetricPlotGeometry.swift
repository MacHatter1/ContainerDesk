import ContainerDeskCore
import SwiftUI

/// The time span and value ceiling that drawing, inspection and accessibility share.
struct ContainerMetricPlotDomain: Equatable {
    let start: Date
    let end: Date
    let upper: Double

    var span: TimeInterval { end.timeIntervalSince(start) }
    var minutes: Int { Int(span / 60) }
    var isDrawable: Bool { span > 0 && span.isFinite && upper > 0 && upper.isFinite }
}

/// One coordinate system for drawing and inspection, including the axis gutters.
struct ContainerMetricPlotCoordinates {
    /// Room for value labels on the leading edge, the peak marker above the
    /// plot and time labels below it.
    static let valueLabelGutter: CGFloat = 42
    static let topInset: CGFloat = 4
    static let timeLabelGutter: CGFloat = 20

    let domain: ContainerMetricPlotDomain
    let size: CGSize

    var frame: CGRect {
        CGRect(x: Self.valueLabelGutter, y: Self.topInset,
               width: max(0, size.width - Self.valueLabelGutter),
               height: max(0, size.height - Self.topInset - Self.timeLabelGutter))
    }

    func x(for date: Date) -> CGFloat? {
        guard domain.span > 0, domain.span.isFinite, date >= domain.start, date <= domain.end else { return nil }
        return frame.minX + CGFloat(date.timeIntervalSince(domain.start) / domain.span) * frame.width
    }

    /// Values are clamped to the domain so a marker never leaves the plot frame.
    func y(for value: Double) -> CGFloat? {
        guard domain.upper > 0, domain.upper.isFinite, value.isFinite else { return nil }
        return frame.maxY - CGFloat(min(1, max(0, value / domain.upper))) * frame.height
    }

    func date(at location: CGPoint) -> Date? {
        guard frame.width > 0, frame.height > 0, frame.contains(location), domain.span > 0, domain.span.isFinite else { return nil }
        return domain.start.addingTimeInterval(Double((location.x - frame.minX) / frame.width) * domain.span)
    }
}

struct ContainerMetricPlotPaths {
    /// Event rules and accessibility series use this order, matching the legend.
    static let eventKinds: [ContainerHistoryEvent.Kind] = [.restart, .exit, .limits]

    let line: Path
    let area: Path
    let eventRules: [(kind: ContainerHistoryEvent.Kind, path: Path)]

    /// Split before constructing curves, so interpolation never bridges a gap.
    static func segments(_ points: [ContainerChartPoint]) -> [[ContainerChartPoint]] {
        var result: [[ContainerChartPoint]] = []
        for point in points {
            if result.last?.last?.segment != point.segment { result.append([]) }
            result[result.count - 1].append(point)
        }
        return result
    }

    init(points: [ContainerChartPoint], events: [ContainerHistoryEvent], domain: ContainerMetricPlotDomain) {
        guard domain.isDrawable else {
            line = Path(); area = Path(); eventRules = []; return
        }
        let span = domain.span
        var line = Path()
        var area = Path()
        for segment in Self.segments(points) {
            let values = segment.map { CGPoint(x: $0.date.timeIntervalSince(domain.start) / span, y: 1 - $0.value / domain.upper) }
            guard let first = values.first, let last = values.last else { continue }
            let curve = Self.monotoneCurve(values)
            line.addPath(curve)
            var fill = curve
            fill.addLine(to: CGPoint(x: last.x, y: 1))
            fill.addLine(to: CGPoint(x: first.x, y: 1))
            fill.closeSubpath()
            area.addPath(fill)
        }
        self.line = line; self.area = area
        eventRules = Self.eventKinds.map { kind in
            var path = Path()
            for event in events where event.kind == kind {
                let x = event.date.timeIntervalSince(domain.start) / span
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 1))
            }
            return (kind, path)
        }
    }

    /// Monotone cubic Hermite interpolation: extrema and flat spans cannot overshoot.
    private static func monotoneCurve(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let slopes = zip(points, points.dropFirst()).map { left, right in
            right.x > left.x ? (right.y - left.y) / (right.x - left.x) : 0
        }
        var tangents = [slopes[0]]
        for index in 1..<(points.count - 1) {
            let a = slopes[index - 1], b = slopes[index]
            tangents.append(a * b <= 0 ? 0 : (a + b) / 2)
        }
        tangents.append(slopes[slopes.count - 1])
        for index in slopes.indices {
            let slope = slopes[index]
            if slope == 0 { tangents[index] = 0; tangents[index + 1] = 0; continue }
            let a = tangents[index] / slope, b = tangents[index + 1] / slope
            let magnitude = hypot(a, b)
            if magnitude > 3 {
                let scale = 3 / magnitude
                tangents[index] = scale * a * slope; tangents[index + 1] = scale * b * slope
            }
        }
        for index in slopes.indices {
            let left = points[index], right = points[index + 1], dx = (right.x - left.x) / 3
            path.addCurve(to: right,
                          control1: CGPoint(x: left.x + dx, y: left.y + tangents[index] * dx),
                          control2: CGPoint(x: right.x - dx, y: right.y - tangents[index + 1] * dx))
        }
        return path
    }
}

/// Unit-space paths survive resizing and hover; only changed plot inputs rebuild them.
/// Unchanged inputs arrive in the same array storage, so comparing them is cheap.
@MainActor final class ContainerMetricPlotPathCache {
    private struct Inputs: Equatable {
        let points: [ContainerChartPoint]
        let events: [ContainerHistoryEvent]
        let domain: ContainerMetricPlotDomain
    }

    private var built: (inputs: Inputs, paths: ContainerMetricPlotPaths)?
    private(set) var buildCount = 0

    func value(points: [ContainerChartPoint], events: [ContainerHistoryEvent], domain: ContainerMetricPlotDomain) -> ContainerMetricPlotPaths {
        let inputs = Inputs(points: points, events: events, domain: domain)
        if let built, built.inputs == inputs { return built.paths }
        let paths = ContainerMetricPlotPaths(points: points, events: events, domain: domain)
        built = (inputs, paths)
        buildCount += 1
        return paths
    }
}
