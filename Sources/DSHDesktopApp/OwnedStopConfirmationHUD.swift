import SwiftUI

/// 轻量原生退出确认层。它只发出“取消”意图；再次 ⌘Q 的确认仍由
/// AppDelegate -> AppCoordinator 的 AppKit 退出回调处理。
struct QuitConfirmationHUD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let stopsOwnedService: Bool
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(reduceTransparency ? 0.30 : 0.16)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    CommandQKeyCaps()

                    VStack(alignment: .leading, spacing: 5) {
                        Text(stopsOwnedService ? "再次按 ⌘Q 停止并退出" : "再次按 ⌘Q 退出")
                            .font(.title3.weight(.semibold))
                        Text(
                            stopsOwnedService
                                ? "仅停止本次由 DSD Pancake 启动的 DSH。"
                                : "不会停止任何并非本 App 启动的 DSH 服务。"
                        )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        HStack(spacing: 6) {
                            Text("取消")
                            Text("Esc")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                    Spacer(minLength: 0)

                    Text("4 秒未确认将自动取消")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(26)
            .frame(maxWidth: 560, alignment: .leading)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(reduceTransparency ? 0.22 : 0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            stopsOwnedService
                ? "退出确认。再次按 Command Q 停止本次 DSH 并退出；四秒后自动取消。"
                : "退出确认。再次按 Command Q 退出；不会停止外部 DSH 服务；四秒后自动取消。"
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct CommandQKeyCaps: View {
    var body: some View {
        HStack(spacing: 6) {
            KeyCap(label: "⌘")
            KeyCap(label: "Q")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Command Q")
    }
}

private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .frame(width: 42, height: 40)
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            }
    }
}
