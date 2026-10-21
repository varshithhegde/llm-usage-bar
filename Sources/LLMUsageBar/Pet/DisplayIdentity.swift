import AppKit
import CoreGraphics

enum DisplayIdentity {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Stable id: the display's UUID, or else vendor/model/serial plus its name.
    static func stableID(of screen: NSScreen) -> String {
        guard let did = displayID(of: screen) else { return "name:\(screen.localizedName)" }
        if let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, cf) as String? {
            return s
        }
        return "vms:\(CGDisplayVendorNumber(did))-\(CGDisplayModelNumber(did))-\(CGDisplaySerialNumber(did))-\(screen.localizedName)"
    }

    static func info(for screen: NSScreen) -> DisplayInfo {
        DisplayInfo(id: stableID(of: screen), name: screen.localizedName, frame: screen.frame,
                    visibleFrame: screen.visibleFrame, isMain: screen.frame.origin == .zero)
    }

    static var connected: [DisplayInfo] { NSScreen.screens.map(info(for:)) }
}
