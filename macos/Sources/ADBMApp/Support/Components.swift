// Small reusable views: the native counterparts of frontend/src/components.tsx.
import ADBMCore
import SwiftUI

// MARK: Surfaces

/// A grouped panel. Liquid Glass on macOS 26+, a standard material below.
struct Panel<Content: View, Accessory: View>: View {
    var title: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.accessory = accessory; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    accessory()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 12)
    }
}

extension View {
    @ViewBuilder
    func surface(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.10)))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.6)))
        }
    }

    /// Disables a write control on a read-only account and explains why.
    func writeGuard(_ readOnly: Bool, help: String = "") -> some View {
        self.disabled(readOnly)
            .help(readOnly ? Fmt.readOnlyHelp : help)
    }
}

struct StatCard: View {
    let label: String
    let value: Int
    var sub: String? = nil
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption).foregroundStyle(.secondary).tracking(0.5)
            Text("\(value)").font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                .contentTransition(.numericText())
            if let sub { Text(sub).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(cornerRadius: 12)
    }
}

struct EmptyState: View {
    let title: String
    var systemImage: String = "tray"
    var text: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let text { Text(text) }
        }
    }
}

struct InlineError: View {
    let message: String
    var onSignIn: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let onSignIn, looksLikeExpiredSignIn(message) {
                Button("Sign in", systemImage: "person.badge.key", action: onSignIn)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

// MARK: Badges

struct Pill: View {
    let text: String
    let tone: Tone
    var body: some View {
        Label(text, systemImage: tone.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.14), in: .capsule)
            .fixedSize()
    }
}

struct StatusPill: View {
    let status: String
    var body: some View { Pill(text: status, tone: Fmt.statusTone(status)) }
}

struct SourceBadge: View {
    let source: SnapshotSource
    var body: some View { Pill(text: Fmt.source(source), tone: Fmt.sourceTone(source)) }
}

struct EncryptedBadge: View {
    let encrypted: Bool
    var body: some View {
        Label(encrypted ? "Encrypted" : "Not encrypted", systemImage: encrypted ? "lock.fill" : "lock.open")
            .font(.caption)
            .foregroundStyle(encrypted ? .green : .orange)
            .fixedSize()
    }
}

struct ProdBadge: View {
    var body: some View {
        Label("Production", systemImage: "checkmark.shield")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.12), in: .capsule)
            .fixedSize()
    }
}

struct ReadOnlyBadge: View {
    var compact = false
    var body: some View {
        Label(compact ? "RO" : "Read-only", systemImage: "lock.fill")
            .font(.system(size: compact ? 9 : 11, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(Color.orange.opacity(0.15), in: .capsule)
            .fixedSize()
            .help("Write actions are disabled for this account")
    }
}

struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 22
    var body: some View {
        Circle().fill(Color.account(account))
            .frame(width: size, height: size)
            .overlay(Text(Fmt.initials(account.name)).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .help(account.name)
    }
}

struct StatusDot: View {
    let status: AccountStatus?
    var body: some View {
        if let status {
            Circle()
                .fill(status.state == .ok ? Color.green : status.state == .expired ? .orange : .red)
                .frame(width: 7, height: 7)
                .help(status.state == .ok ? "Connected" : status.state == .expired ? "Sign-in expired" : status.message)
        }
    }
}

struct RelativeTime: View {
    let value: String?
    var body: some View { Text(Fmt.ago(value)).help(Fmt.full(value)).monospacedDigit() }
}

/// Key/value rows like v0.1's `<dl class="kv">`.
struct KV: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled).gridColumnAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.body)
    }
}

struct ToastHost: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.toasts) { t in
                HStack(spacing: 8) {
                    Image(systemName: t.kind == .success ? "checkmark.circle.fill" : t.kind == .error ? "xmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(t.kind == .success ? .green : t.kind == .error ? .red : .blue)
                    Text(t.message).lineLimit(3)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .surface(cornerRadius: 10)
                .shadow(radius: 6, y: 2)
                .onTapGesture { model.dismissToast(t) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.snappy, value: model.toasts)
    }
}
