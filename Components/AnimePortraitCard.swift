import SwiftUI

// MARK: - 源选择器

struct AnimeSourcePicker: View {
    @Binding var selectedRule: AnimeRule?
    let rules: [AnimeRule]
    var onChange: () -> Void = {}

    var body: some View {
        Menu {
            Button("全部源") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedRule = nil
                }
                onChange()
            }

            Divider()

            ForEach(rules) { rule in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedRule = rule
                    }
                    onChange()
                } label: {
                    HStack {
                        Text(rule.name)
                        if selectedRule?.id == rule.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))

                Text(selectedRule?.name ?? "全部源")
                    .font(.system(size: 13, weight: .semibold))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlassSurface(
                .regular,
                in: Capsule(style: .continuous)
            )
        }
        .menuStyle(.borderlessButton)
    }
}
