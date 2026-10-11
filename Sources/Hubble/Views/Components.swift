import AppKit
import SwiftUI

enum Theme {
    static let gradient = LinearGradient(colors: [Color(red: 0.36, green: 0.33, blue: 0.98),
                                                  Color(red: 0.72, green: 0.34, blue: 0.95),
                                                  Color(red: 0.98, green: 0.45, blue: 0.62)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let growth = Color.orange
    static let cleanup = Color(red: 0.2, green: 0.75, blue: 0.55)
}

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func relative(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: Date())
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct SizeBar: View {
    let fraction: Double
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.gradient)

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.cleanup

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct ItemRow: View {
    let path: String
    let title: String
    let subtitle: String
    let size: String
    let fraction: Double
    var badges: [(String, Color)] = []
    var sizeColor: Color = .primary
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Icons.icon(for: path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    ForEach(badges.indices, id: \.self) { i in Badge(text: badges[i].0, color: badges[i].1) }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 16)
            SizeBar(fraction: fraction).frame(width: 120)
            Text(size)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(sizeColor)
                .frame(width: 84, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(showsChevron ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PathActions: ViewModifier {
    @EnvironmentObject var model: AppModel
    let path: String
    var node: FileNode?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Reveal in Finder") { model.reveal(path) }
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Divider()
            Button("Move to Trash…", role: .destructive) {
                if let node { model.requestTrash([node]) } else { model.requestTrash(path: path) }
            }
        }
    }
}

extension View {
    func pathActions(_ path: String, node: FileNode? = nil) -> some View {
        modifier(PathActions(path: path, node: node))
    }
}

struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct NeedsScanView: View {
    @EnvironmentObject var model: AppModel
    var title = "No scan yet"
    var message = "Run a scan to see what's taking up space."

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "scope")
        } description: {
            Text(message)
        } actions: {
            Button("Scan \(model.rootDisplayName)") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isScanning)
        }
    }
}
