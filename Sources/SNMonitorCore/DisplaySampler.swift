import Foundation
import AppKit
import CoreGraphics

/// Current main-display mode: nominal refresh rate and native pixel size.
public final class DisplaySampler {
    public init() {}

    public func sample() -> DisplaySnapshot {
        var snapshot = DisplaySnapshot.zero

        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
            snapshot.refreshRate = mode.refreshRate
            snapshot.pixelWidth = mode.pixelWidth
            snapshot.pixelHeight = mode.pixelHeight
        }

        if let screen = NSScreen.main {
            snapshot.name = screen.localizedName
        } else if !snapshot.name.isEmpty {
            snapshot.name = "显示器"
        }

        return snapshot
    }
}
