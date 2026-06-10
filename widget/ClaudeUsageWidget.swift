// Claude Usage — real WidgetKit widget (macOS 14+, 出现在「编辑小组件」画廊)
//
// Data: reads ONE file from THIS extension's OWN sandbox container —
//   <container>/Library/Application Support/ClaudeUsage/usage.json
// The desktop floating app (ClaudeUsage, non-sandboxed) mirrors the live
// usage+plan JSON into that path every poll. Reading our own container needs
// NO entitlement beyond app-sandbox — so no provisioning profile is required,
// only a Team-ID code-signing identity (which is what chronod's gallery cache
// gate demands). Countdown texts self-update via Text(_, style: .relative).

import WidgetKit
import SwiftUI
import AppIntents
import os.log

let trace = Logger(subsystem: "local.claude-usage-widget.widget", category: "trace")

// MARK: - Model

struct LimitWindow {
    let key: String
    let usedPct: Double
    let resetsAt: Date?
    var expired: Bool { (resetsAt?.timeIntervalSinceNow ?? 1) <= 0 }
    var remaining: Double { expired ? 100 : max(0, min(100, 100 - usedPct)) }
}

struct Snapshot {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var extras: [LimitWindow] = []
    var updatedAt: Date?
    var plan: String = "—"
    var hasData: Bool { fiveHour != nil || sevenDay != nil || !extras.isEmpty }
}

// MARK: - Loading (own container only)

// Mirrored file inside our sandbox container; the floating app writes here.
func usageFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
    return base.appendingPathComponent("ClaudeUsage/usage.json")
}

private let iso1: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let iso2: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseDate(_ v: Any?) -> Date? {
    if let n = v as? NSNumber {
        var t = n.doubleValue
        if t > 1e12 { t /= 1000 }
        return t > 1e9 ? Date(timeIntervalSince1970: t) : nil
    }
    if let s = v as? String {
        if let d = iso1.date(from: s) ?? iso2.date(from: s) { return d }
        var t = Double(s) ?? 0
        if t > 1e12 { t /= 1000 }
        return t > 1e9 ? Date(timeIntervalSince1970: t) : nil
    }
    return nil
}

func parseWindow(_ key: String, _ dict: [String: Any]) -> LimitWindow? {
    let p = (dict["used_percentage"] ?? dict["utilization"] ?? dict["used_pct"]) as? NSNumber
    guard let p, p.doubleValue >= 0 else { return nil }
    return LimitWindow(key: key,
                       usedPct: min(100, p.doubleValue),
                       resetsAt: parseDate(dict["resets_at"] ?? dict["reset_at"]))
}

func classify(_ windows: [String: [String: Any]], into snap: inout Snapshot) {
    var extras: [LimitWindow] = []
    for (key, w) in windows {
        guard let lw = parseWindow(key, w) else { continue }
        let k = key.lowercased()
        let perModel = k.contains("opus") || k.contains("sonnet") ||
                       k.contains("haiku") || k.contains("fable")
        if !perModel && (k == "five_hour" || k.contains("session")) { snap.fiveHour = lw }
        else if !perModel && (k == "seven_day" || k.contains("week")) { snap.sevenDay = lw }
        else { extras.append(lw) }
    }
    snap.extras = extras.sorted { $0.key < $1.key }
}

func loadSnapshot() -> Snapshot {
    var snap = Snapshot()
    guard let d = try? Data(contentsOf: usageFileURL()),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { trace.info("loadSnapshot: \("no file", privacy: .public)"); return snap }

    snap.updatedAt = parseDate(j["updated_at"])
    if let p = j["plan"] as? String { snap.plan = p }
    var wins = j["windows"] as? [String: [String: Any]]
    if wins == nil {
        var m: [String: [String: Any]] = [:]
        if let f = j["five_hour"] as? [String: Any] { m["five_hour"] = f }
        if let s = j["seven_day"] as? [String: Any] { m["seven_day"] = s }
        wins = m
    }
    if let wins { classify(wins, into: &snap) }
    trace.info("loadSnapshot: 5h=\(snap.fiveHour != nil, privacy: .public) 7d=\(snap.sevenDay != nil, privacy: .public)")
    return snap
}

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snap: Snapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        var s = Snapshot()
        s.fiveHour = LimitWindow(key: "five_hour", usedPct: 34, resetsAt: Date().addingTimeInterval(2700))
        s.sevenDay = LimitWindow(key: "seven_day", usedPct: 21, resetsAt: Date().addingTimeInterval(250000))
        s.plan = "Pro"; s.updatedAt = Date()
        return UsageEntry(date: Date(), snap: s)
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snap: loadSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: Date(), snap: loadSnapshot())
        // Refresh roughly every 5 min; system schedules within budget. The
        // floating app keeps the file minute-fresh, so each reload is current.
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Views

func remainColor(_ rem: Double) -> Color {
    if rem < 15 { return Color(red: 1.00, green: 0.27, blue: 0.23) }
    if rem < 30 { return Color(red: 1.00, green: 0.62, blue: 0.04) }
    if rem < 55 { return Color(red: 1.00, green: 0.84, blue: 0.04) }
    return Color(red: 0.19, green: 0.82, blue: 0.35)
}
func planColor(_ plan: String) -> Color {
    let p = plan.lowercased()
    if p.contains("max") { return Color(red: 0.95, green: 0.66, blue: 0.10) }
    if p.contains("team") || p.contains("enter") { return Color(red: 0.66, green: 0.42, blue: 0.97) }
    if p.contains("pro") { return Color(red: 0.07, green: 0.51, blue: 0.96) }
    return Color(white: 0.45)
}

struct Ring: View {
    let window: LimitWindow?
    let size: CGFloat
    let lineWidth: CGFloat
    var fontSize: CGFloat = 17
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            if let w = window {
                let rem = w.remaining
                Circle().trim(from: 0, to: rem / 100)
                    .stroke(remainColor(rem), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(rem.rounded()))%")
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(remainColor(rem))
                    if w.expired {
                        Text("已重置").font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("—").font(.system(size: fontSize, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct PlanPill: View {
    let plan: String
    var body: some View {
        Text(plan).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(planColor(plan)))
    }
}

struct ResetLine: View {
    let label: String
    let date: Date?
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            if let d = date {
                if d.timeIntervalSinceNow > 0 {
                    Text(d, style: .relative)
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                } else {
                    Text("已重置").font(.system(size: 9, weight: .semibold)).foregroundStyle(.green)
                }
            } else {
                Text("—").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.lineLimit(1).minimumScaleFactor(0.7)
    }
}

// Tapping writes a "ping" into our container; the floating app sees it, fetches
// fresh data from the API, updates the mirror, and reloads us. We also reload
// immediately so the press feels responsive (shows current mirror at once).
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新用量"
    func perform() async throws -> some IntentResult {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeUsage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(Date().timeIntervalSince1970)
        try? stamp.data(using: .utf8)?.write(to: dir.appendingPathComponent("refresh-ping"))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

struct SmallView: View {
    let snap: Snapshot
    var body: some View {
        VStack(spacing: 6) {
            HStack { PlanPill(plan: snap.plan); Spacer(); RefreshButton() }
            Spacer(minLength: 2)
            Ring(window: snap.fiveHour, size: 70, lineWidth: 8, fontSize: 18)
            Text("5小时剩余 · 所有模型").font(.system(size: 8.5)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            HStack(spacing: 5) {
                Text("7天").font(.system(size: 9)).foregroundStyle(.secondary)
                if let w = snap.sevenDay {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(remainColor(w.remaining))
                                .frame(width: max(4, g.size.width * w.remaining / 100))
                        }
                    }.frame(height: 5)
                    Text("\(Int(w.remaining.rounded()))%")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(remainColor(w.remaining))
                } else {
                    Spacer(); Text("—").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MediumView: View {
    let snap: Snapshot
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                Ring(window: snap.fiveHour, size: 72, lineWidth: 8, fontSize: 17)
                VStack(spacing: 1) {
                    Text("5小时剩余").font(.system(size: 9, weight: .semibold))
                    Text("所有模型").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                Ring(window: snap.sevenDay, size: 72, lineWidth: 8, fontSize: 17)
                VStack(spacing: 1) {
                    Text("7天剩余").font(.system(size: 9, weight: .semibold))
                    Text("全部用量").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack { PlanPill(plan: snap.plan); Spacer(); RefreshButton() }
                ResetLine(label: "5小时重置", date: snap.fiveHour?.resetsAt)
                ResetLine(label: "7天重置", date: snap.sevenDay?.resetsAt)
                ForEach(snap.extras, id: \.key) { w in
                    HStack(spacing: 4) {
                        Text(extraLabel(w.key)).font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("\(Int(w.remaining.rounded()))%")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(remainColor(w.remaining))
                    }
                }
                if let u = snap.updatedAt {
                    (Text(u, style: .relative) + Text(" 前更新"))
                        .font(.system(size: 7.5)).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func extraLabel(_ key: String) -> String {
        let k = key.lowercased()
        if k.contains("opus") { return "Opus" }
        if k.contains("sonnet") { return "Sonnet" }
        if k.contains("haiku") { return "Haiku" }
        return key.replacingOccurrences(of: "seven_day_", with: "")
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry
    var body: some View {
        Group {
            if !entry.snap.hasData {
                VStack(spacing: 6) {
                    Text("暂无数据").font(.system(size: 13, weight: .semibold))
                    Text("启动 ClaudeUsage 应用\n或在 Claude Code 发条消息")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if family == .systemSmall {
                SmallView(snap: entry.snap)
            } else {
                MediumView(snap: entry.snap)
            }
        }
        // Match the system widget card (Calendar/Notes): pure white in light
        // mode, dark gray in dark mode. windowBackgroundColor is light-GRAY, so
        // use textBackgroundColor for the true white/dark-card look.
        .containerBackground(for: .widget) { Color(nsColor: .textBackgroundColor) }
    }
}

// MARK: - Widget

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeUsageWidget", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude 用量")
        .description("Claude 订阅额度：5小时 / 7天剩余")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget { ClaudeUsageWidget() }
}
