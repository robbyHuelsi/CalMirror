import SwiftUI

struct GlassTileView<Subtitle: View>: View {
    let systemImage: String
    let title: String
    let tintColor: Color
    @ViewBuilder let subtitle: Subtitle

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(tintColor.gradient)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

extension GlassTileView where Subtitle == Text {
    init(systemImage: String, title: String, subtitleText: String, tintColor: Color) {
        self.systemImage = systemImage
        self.title = title
        self.tintColor = tintColor
        self.subtitle = Text(subtitleText)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: 12) {
            GlassTileView(systemImage: "calendar", title: "Synced Events", subtitleText: "42 events", tintColor: .blue)
            GlassTileView(systemImage: "checklist", title: "Active Calendars", subtitleText: "3 calendars", tintColor: .green)
            GlassTileView(systemImage: "server.rack", title: "Server", subtitleText: "cal.example.com", tintColor: .orange)
            GlassTileView(systemImage: "arrow.triangle.2.circlepath", title: "Synchronization", subtitleText: "5 min ago", tintColor: .purple)
        }
        .padding(.horizontal, 16)
    }
}
#endif
