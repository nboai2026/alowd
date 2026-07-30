import Foundation

public struct PermissionStatus: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public var blockingMessage: String? {
        var missing: [String] = []
        if !microphone { missing.append("microphone") }
        if !accessibility { missing.append("accessibility") }
        if !inputMonitoring { missing.append("input monitoring") }
        if missing.isEmpty { return nil }
        return "Alowd needs \(missing.formattedList) permission before dictation can work."
    }
}

private extension Array where Element == String {
    var formattedList: String {
        if count == 1 { return self[0] }
        if count == 2 { return "\(self[0]) and \(self[1])" }
        return dropLast().joined(separator: ", ") + ", and " + (last ?? "")
    }
}
