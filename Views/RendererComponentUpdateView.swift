import SwiftUI

/// Component release notes take precedence; executable names and versions are available on demand.
struct RendererComponentUpdateView: View {
    @ObservedObject var updater: RendererComponentUpdater
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: updater.didInstall ? "checkmark.circle" : "shippingbox")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("渲染组件更新").font(.system(size: 20, weight: .semibold))
                    Text("独立更新壁纸引擎，无需重新安装 WaifuX")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { updater.closeWindow() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .modifier(RendererComponentActionStyle())
                .controlSize(.small)
                .accessibilityLabel("关闭组件更新窗口")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    updateContent
                }
                .onChange(of: showsDetails) { _, expanded in
                    proxy.scrollTo(expanded ? "component-details" : "component-updates", anchor: .top)
                }
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                if updater.isInstalling {
                    ProgressView(value: updater.progress)
                        .accessibilityLabel("组件下载进度")
                }
                HStack(spacing: 8) {
                    if updater.isChecking { ProgressView().controlSize(.small) }
                    if updater.didInstall {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(updater.status).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if updater.isInstalling {
                        Text("\(Int(updater.progress * 100))%")
                            .monospacedDigit().fixedSize()
                    } else if !updater.updates.isEmpty {
                        Text(downloadSize).monospacedDigit().fixedSize()
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if !updater.updates.isEmpty || updater.didInstall {
                    Text("更新不会中断当前壁纸。\n关闭并重新开启对应动态壁纸后使用新版本。")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            actions
                .controlSize(.large)
                .glassContainer(spacing: 8)
        }
        .padding(24)
        .frame(width: 520, height: 440)
        .foregroundStyle(.primary)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var updateContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = updater.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(updater.updates) { release in
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallpaperTitle(release.component))
                        .font(.system(size: 13, weight: .semibold))
                    Text(release.notes.isEmpty ? "更新至 \(release.version)" : release.notes)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup("组件详情", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(RendererComponent.allCases) { component in
                        componentDetails(component)
                    }
                    Divider()
                    Text("新版本在对应渲染进程下次启动时生效。仅切换壁纸或关闭主窗口可能复用原进程；关闭并重新开启对应动态壁纸后，才会使用新版本。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 12)
            }
            .font(.callout).foregroundStyle(.secondary)
            .id("component-details")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("component-updates")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if updater.isInstalling {
                Button("取消下载") { updater.cancelInstallation() }
                    .modifier(RendererComponentActionStyle())
                Spacer()
            } else if !updater.updates.isEmpty {
                Button("跳过这些版本") { updater.skipVersions() }
                    .font(.callout).buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(updater.isChecking)
                Spacer()
                Button("稍后") { updater.closeWindow() }
                    .modifier(RendererComponentActionStyle()).keyboardShortcut(.cancelAction)
                Button("更新组件") { updater.install() }
                    .modifier(RendererComponentActionStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction).disabled(updater.isChecking)
            } else {
                Button("重新检查") { updater.check(userInitiated: true) }
                    .modifier(RendererComponentActionStyle()).disabled(updater.isChecking)
                Spacer()
                Button("完成") { updater.closeWindow() }
                    .modifier(RendererComponentActionStyle(isPrimary: true)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: updater.updates.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
    }

    private func wallpaperTitle(_ component: RendererComponent) -> String {
        switch component {
        case .wgpu: return "场景壁纸"
        case .web: return "网页壁纸"
        case .video: return "视频壁纸"
        }
    }

    private func componentDetails(_ component: RendererComponent) -> some View {
        let release = updater.updates.first { $0.component == component }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(component.title)
                Spacer(minLength: 12)
                if let release {
                    Text("\(updater.versions[component] ?? "读取中…") → \(release.version)")
                        .monospacedDigit()
                } else {
                    Text(updater.versions[component] ?? "读取中…").monospacedDigit()
                }
            }
            Text(component.executable).font(.caption.monospaced())
        }
    }
}

/// Let the system own glass rendering, focus, pressed states and accessibility appearance.
private struct RendererComponentActionStyle: ViewModifier {
    var isPrimary = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isPrimary {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else if isPrimary {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
