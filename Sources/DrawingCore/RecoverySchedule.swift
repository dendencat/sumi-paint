/// A quiet-period save with a deadline that continued editing cannot postpone.
public struct RecoverySchedule: Sendable {
    public var idleDelay: Double
    public var maximumInterval: Double
    private var firstChange: Double?
    private var lastChange: Double?
    public init(idleDelay: Double = 2, maximumInterval: Double = 10) {
        self.idleDelay = idleDelay; self.maximumInterval = maximumInterval
    }
    public mutating func noteChange(at time: Double) {
        firstChange = min(firstChange ?? time, time)
        lastChange = max(lastChange ?? time, time)
    }
    public func delay(at time: Double) -> Double? {
        guard let firstChange, let lastChange else { return nil }
        return max(0, min(lastChange + idleDelay, firstChange + maximumInterval) - time)
    }
    public mutating func reset() { firstChange = nil; lastChange = nil }
}
