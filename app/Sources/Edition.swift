import Foundation

/// This is Dual Scan III: the edition for the Minolta Dimage Scan Dual III. It is a separate app
/// from Dual Scan (the Dual IV one) — its own name, settings, scans folder and updates — so the two
/// never get in each other's way, even on the same Mac.
enum Edition {
    static let name = "Dual Scan III"
    static let model = "Dimage Scan Dual III"
    /// The scanners it looks for, as the driver names them.
    static let supportedModels = ["Dual III"]
    /// What the simulator plays.
    static let simulated = ScannerCapabilities.dualIII
    /// Where it updates from: its own repository, apart from Dual Scan's.
    static let repository = "anantap/dualscan-iii"
    /// Its releases are tagged `build-<n>`.
    static let releaseTagPrefix = "build-"
    static let releaseAsset = "Dual-Scan-III.zip"
}
