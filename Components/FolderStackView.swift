import SwiftUI
import Kingfisher

// MARK: - 文件夹叠放预览

struct FolderStackView: View {
    let imageURLs: [URL]
    let size: CGSize

    var body: some View {
        ZStack {
            if imageURLs.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: min(size.width, size.height) * 0.35, weight: .light))
                    .foregroundStyle(.white.opacity(0.1))
            } else {
                stackContent
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var stackContent: some View {
        ZStack {
            let count = min(imageURLs.count, 4)

            // 从后往前画：数组[0]是最新/最重要的，应该在最上面
            ForEach(0..<count, id: \.self) { index in
                let url = imageURLs[index]
                let cfg = config(for: index)

                KFImage(url)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width * 0.75, height: size.height * 0.68)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 5, x: 0, y: 2)
                    .offset(x: cfg.x, y: cfg.y)
                    .rotationEffect(.degrees(cfg.rot))
                    .opacity(cfg.opacity)
                    .zIndex(Double(count - index))
            }
        }
    }

    /// 堆叠配置：固定像素偏移，确保边缘明显露出（index 0 = 最顶层）
    private func config(for index: Int) -> (x: CGFloat, y: CGFloat, rot: Double, opacity: Double) {
        switch index {
        case 0: return (16, 10, 0, 1.0)       // 顶层：偏右下
        case 1: return (-18, -14, -4, 0.90)   // 左上露出
        case 2: return (20, -12, 5, 0.75)     // 右上露出
        case 3: return (-14, 16, -3, 0.58)    // 左下露出
        default: return (0, 0, 0, 1.0)
        }
    }
}

// MARK: - 文件夹卡片

struct LibraryFolderCard: View {
    let folder: LibraryFolder
    let previewURLs: [URL]
    let itemCount: Int
    let cardWidth: CGFloat
    let onTap: () -> Void
    let onDrop: ([String]) -> Void
    let onDisband: () -> Void

    @State private var isHovered = false
    @State private var isDropTarget = false

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域
                ZStack {
                    Color(hex: "1A1D24").opacity(0.3)

                    FolderStackView(
                        imageURLs: previewURLs,
                        size: CGSize(width: cardWidth, height: thumbnailHeight)
                    )
                }
                .frame(width: cardWidth, height: thumbnailHeight)
                .clipped()

                // 信息区域（与 WallpaperEditCard 完全一致的结构和高度）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(folder.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 12)

                        folderMetaRow
                    }

                    // 保持和 WallpaperEditCard 的 if progress 结构完全一致
                    EmptyView().frame(height: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: cardWidth, alignment: .leading)
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        isDropTarget
                            ? Color.accentColor.opacity(0.8)
                            : Color.white.opacity(isHovered ? 0.18 : 0.08),
                        lineWidth: isDropTarget ? 2.5 : (isHovered ? 1.5 : 1)
                    )
            )
            .scaleEffect(isHovered || isDropTarget ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(role: .destructive, action: onDisband) {
                Label(t("disband.folder"), systemImage: "folder.badge.minus")
            }
        }
        .dropDestination(for: String.self) { strings, _ in
            let ids = strings.compactMap { str -> String? in
                if str.hasPrefix("waifux:item:") {
                    return String(str.dropFirst(12))
                }
                return nil
            }
            if !ids.isEmpty {
                onDrop(ids)
            }
            return true
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
    }

    /// 与 WallpaperEditCard 的 trailingMetadataRow / statLabel 结构完全一致
    private var folderMetaRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))

            Text("\(itemCount)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
