import Accessibility
import SwiftUI
import Testing
@testable import ContainerDeskCore
@testable import ContainerDeskApp

@MainActor @Suite(.serialized)
struct ContainerMetricPlotGeometryTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func point(_ second: Double, _ value: Double, segment: Int = 0) -> ContainerChartPoint {
        .init(date: start.addingTimeInterval(second), value: value, segment: segment)
    }

    @Test func inspectionUsesTheSamePlotFrameAndDomainAsDrawing() throws {
        let coordinates = ContainerMetricPlotCoordinates(start: start, end: start.addingTimeInterval(60), upper: 100, size: .init(width: 342, height: 124))
        #expect(coordinates.frame == CGRect(x: 42, y: 4, width: 300, height: 100))
        #expect(coordinates.x(for: start) == 42)
        #expect(coordinates.x(for: start.addingTimeInterval(60)) == 342)
        #expect(coordinates.y(for: 0) == 104)
        #expect(coordinates.y(for: 100) == 4)
        let middle = try #require(coordinates.date(at: CGPoint(x: 192, y: 54)))
        #expect(abs(middle.timeIntervalSince(start) - 30) < 0.000_001)
        #expect(coordinates.date(at: CGPoint(x: 20, y: 54)) == nil)
        #expect(coordinates.date(at: CGPoint(x: 192, y: 120)) == nil)
        #expect(coordinates.x(for: start.addingTimeInterval(-1)) == nil)
    }

    @Test func curvesKeepDiscontinuitiesAndExtremaWithoutOvershooting() {
        let points = [point(0, 0), point(1, 10), point(2, 0), point(4, 5, segment: 1), point(5, 5, segment: 1)]
        let paths = ContainerMetricPlotPaths(points: points, events: [], start: start, end: start.addingTimeInterval(5), upper: 10)
        var moves = 0, curves = 0, closes = 0
        paths.line.cgPath.applyWithBlock { element in
            let value = element.pointee
            if value.type == .moveToPoint { moves += 1 }
            if value.type == .addCurveToPoint {
                curves += 1
                for index in 0..<3 {
                    #expect(value.points[index].x >= 0 && value.points[index].x <= 1)
                    #expect(value.points[index].y >= 0 && value.points[index].y <= 1)
                }
            }
        }
        paths.area.cgPath.applyWithBlock { if $0.pointee.type == .closeSubpath { closes += 1 } }
        #expect(moves == 2)
        #expect(curves == 3)
        #expect(closes == 2)
        #expect(paths.line.cgPath.boundingBoxOfPath.minY == 0)
        #expect(paths.line.cgPath.boundingBoxOfPath.maxY == 1)
    }

    @Test func pathCacheInvalidatesForAllDrawingInputsButSurvivesResizingAndSelection() {
        let cache = ContainerMetricPlotPathCache()
        var points = [point(0, 0), point(1, 10)]
        let end = start.addingTimeInterval(5)
        _ = cache.value(points: points, events: [], start: start, end: end, upper: 10)
        _ = cache.value(points: points, events: [], start: start, end: end, upper: 10)
        #expect(cache.buildCount == 1)
        points.append(point(2, 5))
        _ = cache.value(points: points, events: [], start: start, end: end, upper: 10)
        let event = ContainerHistoryEvent(date: start.addingTimeInterval(1), containerID: "fixture", kind: .restart, detail: "Restart", unexpected: false)
        _ = cache.value(points: points, events: [event], start: start, end: end, upper: 10)
        _ = cache.value(points: points, events: [event], start: start.addingTimeInterval(-1), end: end, upper: 10)
        _ = cache.value(points: points, events: [event], start: start.addingTimeInterval(-1), end: end.addingTimeInterval(1), upper: 10)
        _ = cache.value(points: points, events: [event], start: start.addingTimeInterval(-1), end: end.addingTimeInterval(1), upper: 20)
        #expect(cache.buildCount == 6)
    }

    @Test func accessibleChartKeepsTimeUnitsGapsEventsAndUpdates() throws {
        let points = [point(0, 0), point(1, 10), point(4, 5, segment: 1)]
        let event = ContainerHistoryEvent(date: start.addingTimeInterval(2), containerID: "fixture", kind: .restart, detail: "Restarted", unexpected: false)
        func source(_ events: [ContainerHistoryEvent], _ upper: Double) -> ContainerMetricPlotDescriptor {
            .init(title: "CPU", unit: "%", points: points, events: events, start: start, end: start.addingTimeInterval(5), upper: upper, sampleCount: 3)
        }
        let descriptor = source([event], 10).makeChartDescriptor()
        #expect(descriptor.series.map { $0.dataPoints.count } == [2, 1, 1])
        #expect(descriptor.series.map(\.isContinuous) == [true, true, false])
        #expect(descriptor.series.last?.name == "Restart")
        let axis = try #require(descriptor.xAxis as? AXNumericDataAxisDescriptor)
        #expect(axis.range.lowerBound == start.timeIntervalSince1970)
        #expect(axis.range.upperBound == start.addingTimeInterval(5).timeIntervalSince1970)
        #expect(descriptor.yAxis?.valueDescriptionProvider(5).contains("%") == true)
        source([], 20).updateChartDescriptor(descriptor)
        #expect(descriptor.series.count == 2)
        #expect(descriptor.yAxis?.range.upperBound == 20)
    }

    @Test func emptyAndFlatDataHaveValidPathsAndAxisTicks() {
        let empty = ContainerMetricPlotPaths(points: [], events: [], start: start, end: start.addingTimeInterval(5), upper: 1)
        #expect(empty.line.isEmpty && empty.area.isEmpty)
        let flat = ContainerMetricPlotPaths(points: [point(0, 0), point(1, 0)], events: [], start: start, end: start.addingTimeInterval(5), upper: 1)
        #expect(flat.line.cgPath.boundingBoxOfPath.minY == 1)
        #expect(flat.line.cgPath.boundingBoxOfPath.maxY == 1)
        #expect(ContainerMetricPlotAxis.ticks(upper: 1) == [0, 0.5, 1])
        #expect(ContainerMetricPlotAxis.ticks(upper: 0) == [0])
    }
}
