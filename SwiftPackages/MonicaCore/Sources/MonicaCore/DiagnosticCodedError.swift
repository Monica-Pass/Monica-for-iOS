import Foundation

/// An error that can describe itself with a stable diagnostic code instead of a
/// message. Conformances live next to the error type they map, so a new case
/// cannot be added without the compiler pointing at the mapping.
public protocol DiagnosticCodedError: Error, Sendable {
    var diagnosticCode: DiagnosticCode { get }
    var diagnosticReason: DiagnosticTag { get }
    /// Allowlisted, non-secret fields for the event. Conformances may add counts, statuses or
    /// provider tags; the default keeps only the closed reason.
    var diagnosticMetadata: DiagnosticMetadata { get }
}

public extension DiagnosticCodedError {
    var diagnosticMetadata: DiagnosticMetadata {
        .reason(diagnosticReason)
    }
}
