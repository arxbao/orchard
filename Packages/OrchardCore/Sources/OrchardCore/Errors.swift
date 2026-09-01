import Foundation

/// The single error type surfaced to the UI and CLI. Carries the offending
/// command and an actionable message (davit's CLIError, made `public`).
public struct CLIError: LocalizedError, Identifiable {
    public let id = UUID()
    public let command: String
    public let message: String
    public let exitCode: Int32

    public init(command: String, message: String, exitCode: Int32 = -1) {
        self.command = command
        self.message = message
        self.exitCode = exitCode
    }

    public var errorDescription: String? { message }

    public static func wrap(_ operation: String, _ error: Error) -> CLIError {
        CLIError(command: operation, message: "\(operation): \(String(describing: error))")
    }
}
