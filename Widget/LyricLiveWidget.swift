import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LyricLiveWidgetBundle: WidgetBundle {
    var body: some Widget { LyricsLiveActivity() }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricAttributes.self) { context in
            LyricActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.025, green: 0.045, blue: 0.055))
                .activitySystemActionForegroundColor(.mint)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note").foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.source ?? "DÉMO").font(.caption2).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text((context.state.trackTitle ?? context.attributes.title)).font(.caption.bold()).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.line).font(.headline).lineLimit(3)
                        Text(context.isStale ? "Ouvre LyricLive pour actualiser" : (context.state.status ?? (context.state.isPlaying ? "Démo en cours" : "En pause")))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(.mint)
            } compactTrailing: {
                // Also a readable fallback for CarPlay compact presentation.
                Text(context.state.line).font(.caption).lineLimit(1)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(.mint)
            }
            .keylineTint(.mint)
        }
        .supplementalActivityFamilies([.small])
    }
}

struct LyricActivityView: View {
    let context: ActivityViewContext<LyricAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .small ? 5 : 10) {
            HStack(spacing: 6) {
                Image(systemName: "music.note").foregroundStyle(.mint)
                Text((context.state.trackTitle ?? context.attributes.title))
                    .font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 0)
                if family != .small {
                    Text(context.attributes.source ?? "DÉMO").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(context.state.line)
                .font(family == .small ? .headline : .title3.bold())
                .foregroundStyle(.white)
                .lineLimit(family == .small ? 3 : 4)
                .minimumScaleFactor(0.85)
            if family != .small {
                Text(context.state.nextLine).font(.caption).foregroundStyle(.gray).lineLimit(2)
            }
            Text(context.isStale ? "Suivi suspendu · Ouvre LyricLive" : (context.state.status ?? (context.state.isPlaying ? "Démo · Ligne \(context.state.lineNumber)" : "Pause · Ligne \(context.state.lineNumber)")))
                .font(.caption2).foregroundStyle(.gray).lineLimit(1)
        }
        .padding(family == .small ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
