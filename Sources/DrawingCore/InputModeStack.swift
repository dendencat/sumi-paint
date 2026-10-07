/// Tracks independent held controls so releasing one restores the remaining mode.
public struct InputModeStack<Mode: Equatable & Sendable>: Sendable {
    private struct Entry: Sendable {
        let source: String
        var mode: Mode
    }
    public private(set) var baseMode: Mode
    private var entries: [Entry] = []
    public var currentMode: Mode { entries.last?.mode ?? baseMode }
    public var hasOverrides: Bool { !entries.isEmpty }
    public init(baseMode: Mode) { self.baseMode = baseMode }
    public mutating func press(_ source: String, mode: Mode) {
        if let index = entries.firstIndex(where: { $0.source == source }) {
            entries[index].mode = mode
        } else {
            entries.append(.init(source: source, mode: mode))
        }
    }
    public mutating func release(_ source: String) { entries.removeAll { $0.source == source } }
    public mutating func reset(to mode: Mode) { baseMode = mode; entries.removeAll() }
}
