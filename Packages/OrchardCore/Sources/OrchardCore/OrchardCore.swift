/// Root namespace for the Orchard core library.
///
/// OrchardCore is the single backend shared by the GUI app and the
/// `orchard-cli` executable. It wraps Apple's ContainerAPIClient (XPC) and
/// provides domain services, models, and pure logic (compose parsing, stats
/// math, log scanning) that unit tests exercise without a live daemon.
public enum OrchardCore {
    /// The library version, surfaced by the CLI (`orchard version`) and the
    /// app's version label. Bump together with MARKETING_VERSION in the
    /// Xcode project.
    public static let versionString = "0.1.0"
}
