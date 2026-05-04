import SwiftUI

struct SessionListView: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("◆")
                    .font(.system(size: 16, weight: .bold))
                Text("Claude Notch")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text("Hello, Claude Notch — scaffold OK")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320, height: 100)
    }
}

#Preview {
    SessionListView()
}
