import ContainerDeskCore
import SwiftUI

/// One coordinate system for drawing and inspection, including the axis gutters.
struct ContainerMetricPlotCoordinates {
    let start: Date
    let end: Date
    let upper: Double
    let size: CGSize

    var frame: CGRect { CGRect(x: 42, y: 4, width: max(0, size.width - 42), height: max(0, size.height - 24)) }

    func x(for date: Date) -> CGFloat? {
        let span = end.timeIntervalSince(start)
        guard span > 0, span.isFinite, date >= start, date <= end else { return nil }
        return frame.minX + CGFloat(date.timeIntervalSince(start) / span) * frame.width
    }

    func y(for value: Double) -> CGFloat? {
        guard upper > 0, upper.isFinite, value.isFinite else { return nil }
        return frame.maxY - CGFloat(value / upper) * frame.height
    }

    func date(at location: CGPoint) -> Date? {
        let span = end.timeIntervalSince(start)
        guard frame.width > 0, frame.height > 0, frame.contains(location), span > 0, span.isFinite else { return nil }
        return start.addingTimeInterval(Double((location.x - frame.minX) / frame.width) * span)
    }
}

struct ContainerMetricPlotPaths {
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

    init(points: [ContainerChartPoint], events: [ContainerHistoryEvent], start: Date, end: Date, upper: Double) {
        let span = end.timeIntervalSince(start)
        guard span > 0, span.isFinite, upper > 0, upper.isFinite else {
            line = Path(); area = Path(); eventRules = []; return
        }
        var line = Path()
        var area = Path()
        for segment in Self.segments(points) {
            let values = segment.map { CGPoint(x: $0.date.timeIntervalSince(start) / span, y: 1 - $0.value / upper) }
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
        eventRules = [ContainerHistoryEvent.Kind.restart, .exit, .limits].map { kind in
            var path = Path()
            for event in events where event.kind == kind {
                let x = event.date.timeIntervalSince(start) / span
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
@MainActor final class ContainerMetricPlotPathCache {
    private var points: [ContainerChartPoint] = []
    private var events: [ContainerHistoryEvent] = []
    private var start: Date?
    private var end: Date?
    private var upper = 0.0
    private var paths: ContainerMetricPlotPaths?
    private(set) var buildCount = 0

    func value(points: [ContainerChartPoint], events: [ContainerHistoryEvent], start: Date, end: Date, upper: Double) -> ContainerMetricPlotPaths {
        if paths == nil || self.points != points || self.events != events || self.start != start || self.end != end || self.upper != upper {
            self.points = points; self.events = events; self.start = start; self.end = end; self.upper = upper
            paths = ContainerMetricPlotPaths(points: points, events: events, start: start, end: end, upper: upper)
            buildCount += 1
        }
        return paths!
    }
}
