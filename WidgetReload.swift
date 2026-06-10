// Bridge so the ObjC floating app can reload the WidgetKit timelines after it
// fetches fresh data (e.g. when the widget's refresh button pings it).
// WidgetCenter is Swift-only; this @objc shim exposes it to ClaudeUsage.m via
// the generated ClaudeUsage-Swift.h header.
import Foundation
import WidgetKit

@objc(WidgetReloader)
final class WidgetReloader: NSObject {
    @objc static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
