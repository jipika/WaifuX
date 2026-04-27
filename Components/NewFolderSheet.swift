import SwiftUI

struct NewFolderSheet: View {
    @Binding var folderName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text(t("new.folder"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            
            TextField(t("folder.name.placeholder"), text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    onConfirm()
                }
            
            HStack(spacing: 12) {
                Button(t("cancel"), action: onCancel)
                    .buttonStyle(.borderless)
                
                Button(t("create"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
        )
    }
}
