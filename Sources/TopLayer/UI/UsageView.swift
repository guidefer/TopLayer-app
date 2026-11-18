import SwiftUI

/// The usage button in a section's header: a ring that fills as the plan's tightest limit
/// is used. Hovering says how much is used and left; clicking opens the detail.
struct UsageButton: View {
    @ObservedObject var store: Store
    let source: AgentSource
    @State private var hovering = false

    private var showing: Binding<Bool> {
        // Closing one section's detail must not close the other's, which may have just opened.
        Binding(get: { store.usageShown == source },
                set: { if $0 { store.usageShown = source } else if store.usageShown == source { store.usageShown = nil } })
    }

    var body: some View {
        let report = store.usage[source]
        Button {
            store.usageShown = store.usageShown == source ? nil : source
            // Opening it is a reason to look again, unless the reading is fresh.
            if let fetched = report?.fetched, Date().timeIntervalSince(fetched) < 30 { return }
            store.refreshUsage(source, force: true)
        } label: {
            ZStack {
                squircle(Radius.control).fill(.white.opacity(hovering || store.usageShown == source ? 0.18 : 0))
                UsageRing(used: report?.tightest?.used).frame(width: 13, height: 13)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(tooltip(report))
        .accessibilityLabel("\(source.rawValue) usage")
        .accessibilityValue(tooltip(report))
        .popover(isPresented: showing, arrowEdge: .bottom) { UsagePanel(store: store, source: source) }
    }

    private func tooltip(_ report: UsageReport?) -> String {
        if let report, !report.limits.isEmpty { return "\(source.rawValue): \(report.summary())" }
        if store.usageLoading.contains(source) { return "Reading \(source.rawValue) usage…" }
        return store.usageProblem[source] ?? "\(source.rawValue) usage"
    }
}

/// A ring that fills clockwise from the top. With nothing to show it is an empty track.
struct UsageRing: View {
    let used: Int?

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(used == nil ? 0.3 : 0.38), lineWidth: 2.2)
            if let used {
                Circle()
                    .trim(from: 0, to: max(0.03, CGFloat(used) / 100))
                    .stroke(UsageRing.color(used), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.panel, value: used)
            }
        }
        .padding(1.1)
    }

    /// White until a limit is nearly used up; the header's own colour is the section's,
    /// so a warning has to be a colour neither section uses.
    static func color(_ used: Int) -> Color {
        used >= 95 ? Color(red: 1, green: 0.32, blue: 0.3) : used >= 80 ? .yellow : .white
    }
}

/// The detail behind the usage button: every limit with its bar and reset time.
struct UsagePanel: View {
    @ObservedObject var store: Store
    let source: AgentSource

    var body: some View {
        let report = store.usage[source]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(source.rawValue) usage").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = report?.plan {
                    Text(plan).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }
            if let report {
                if report.limits.isEmpty {
                    Text("No plan limits were reported for this account.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(report.limits) { limit in row(limit) }
                if report.credits != nil || report.freeResets > 0 {
                    Divider()
                    if let credits = report.credits { fact("Credits", credits) }
                    if report.freeResets > 0 {
                        fact("Free limit resets", "\(report.freeResets) available")
                    }
                }
            } else if store.usageProblem[source] == nil {
                Text("Reading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let problem = store.usageProblem[source] {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer(report)
        }
        .padding(14)
        .frame(width: 252)
    }

    private func row(_ limit: UsageLimit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(limit.used)% used").font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(barColor(limit.used))
                        .frame(width: max(4, box.size.width * CGFloat(limit.used) / 100))
                }
            }
            .frame(height: 5)
            HStack(alignment: .firstTextBaseline) {
                Text("\(limit.left)% left")
                Spacer()
                if let resets = limit.resets { Text("resets \(Self.when(resets))") }
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func barColor(_ used: Int) -> Color {
        used >= 95 ? .red : used >= 80 ? .yellow : Brand.color(source)
    }

    /// "in 5 days · Sun 17:00" within a week, "in 12 days · Nov 29" beyond it.
    static func when(_ resets: Date, now: Date = Date()) -> String {
        let near = resets.timeIntervalSince(now) < 6.5 * 86400
        let exact = near ? resets.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                         : resets.formatted(.dateTime.month(.abbreviated).day())
        return "\(UsageReport.until(resets, now: now)) · \(exact)"
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }

    private func footer(_ report: UsageReport?) -> some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 20)) { moment in
                Text(report.map { "Updated \(Self.ago($0.fetched, now: moment.date))" } ?? "Not read yet")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            if store.usageLoading.contains(source) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else {
                Button { store.refreshUsage(source, force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Read again").accessibilityLabel("Read usage again")
            }
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }
}
