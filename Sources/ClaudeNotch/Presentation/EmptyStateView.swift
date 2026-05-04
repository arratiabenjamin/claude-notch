// EmptyStateView.swift
// Shown for any of the "nothing to display" UIState branches:
// .empty / .fileMissing / .dirMissing / .decodeError / .sizeLimitExceeded / .schemaMismatch.
import SwiftUI

struct EmptyStateView: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("◇")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
