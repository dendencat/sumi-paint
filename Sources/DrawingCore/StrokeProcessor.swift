import Foundation

public struct StrokeSample: Equatable, Sendable {
    public var point: PaintPoint
    public var time: Double
    public var pressure: Double?
    public init(point: PaintPoint, time: Double, pressure: Double? = nil) {
        self.point = point; self.time = time; self.pressure = pressure
    }
}

public struct BrushDab: Equatable, Sendable {
    public var point: PaintPoint
    public var radius: Double
    public var opacity: Double
}

public struct StrokeProcessor: Sendable {
    public let settings: BrushSettings
    private var filtered: StrokeSample?
    private var raw: StrokeSample?
    private var distanceToNext: Double = 0
    private var traveled: Double = 0
    public init(settings: BrushSettings) { self.settings = settings }
    private func dab(at sample: StrokeSample) -> BrushDab {
        let input = sample.pressure.map { min(1, max(0, $0)) } ?? 1
        let pressure = pow(input, settings.pressurePower)
        var sizeFactor = settings.minimumSize + (1 - settings.minimumSize) * pressure
        if sample.pressure == nil && settings.taperWithoutPressure {
            sizeFactor *= min(1, max(0.12, traveled / max(1, settings.size)))
        }
        return .init(point: sample.point, radius: max(0.5, settings.size * sizeFactor / 2),
                     opacity: settings.opacity * (settings.pressureOpacity ? pressure : 1))
    }
    public mutating func append(_ sample: StrokeSample) -> [BrushDab] {
        guard sample.point.x.isFinite, sample.point.y.isFinite, sample.time.isFinite,
              sample.pressure?.isFinite != false else { return [] }
        if let previous = raw, sample.time < previous.time { return [] }
        raw = sample
        guard let previous = filtered else {
            filtered = sample
            let first = dab(at: sample)
            distanceToNext = max(0.5, first.radius * 2 * settings.spacing)
            return [first]
        }
        let dt = max(1.0 / 240, sample.time - previous.time)
        let tau = settings.stabilization * settings.stabilization * 0.12
        let alpha = tau == 0 ? 1 : 1 - exp(-dt / tau)
        var next = sample
        next.point = previous.point.interpolated(to: sample.point, fraction: alpha)
        return resample(from: previous, to: next)
    }
    private mutating func resample(from previous: StrokeSample, to next: StrokeSample) -> [BrushDab] {
        let distance = previous.point.distance(to: next.point)
        filtered = next
        guard distance > 0.000001 else { return [] }
        var offset = distanceToNext
        var result: [BrushDab] = []
        // A single malformed event must not cause unbounded work.
        while offset <= distance && result.count < 8192 {
            let fraction = offset / distance
            let pressure: Double?
            if let a = previous.pressure, let b = next.pressure { pressure = a + (b - a) * fraction }
            else { pressure = next.pressure }
            traveled += distanceToNext
            let value = dab(at: .init(point: previous.point.interpolated(to: next.point, fraction: fraction),
                                     time: next.time, pressure: pressure))
            result.append(value)
            distanceToNext = max(0.5, value.radius * 2 * settings.spacing)
            offset += distanceToNext
        }
        distanceToNext = max(0, offset - distance)
        return result
    }
    public mutating func finish() -> [BrushDab] {
        guard let actual = raw, let previous = filtered else { return [] }
        var result = resample(from: previous, to: actual)
        let last = dab(at: actual)
        if result.last?.point.distance(to: actual.point) ?? previous.point.distance(to: actual.point) > 0.5 {
            result.append(last)
        }
        return result
    }
}
