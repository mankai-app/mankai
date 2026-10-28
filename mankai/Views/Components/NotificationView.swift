//
//  NotificationView.swift
//  mankai
//
//  Created by Travis XU on 21/12/2025.
//

import SwiftUI

struct NotificationView: View {
    let notification: AppNotification
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: iconName).foregroundStyle(iconColor)
                    .font(.system(size: 18, weight: .semibold))

                Text(notification.message).font(.system(size: 14)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 16).padding(.vertical, 12)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    .font(.system(size: 18)).padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .applyGlassBackground().padding(.horizontal, 16).offset(y: dragOffset)
        .opacity(1 - Double(abs(dragOffset) / 200)).contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { gesture in
                    if gesture.translation.height > 0 { dragOffset = gesture.translation.height }
                }
                .onEnded { gesture in
                    if gesture.translation.height > 50 {
                        withAnimation(.easeOut(duration: 0.3)) { dragOffset = 300 }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            onDismiss()
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                })
    }

    private var iconName: String {
        switch notification.type { case .error: return "exclamationmark.circle.fill" case .warning:
            return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch notification.type { case .error: return .red case .warning: return .orange
            case .success: return .green
            case .info: return .blue
        }
    }
}

// MARK: - Glass Background Extension

extension View {
    @ViewBuilder fileprivate func applyGlassBackground() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect().clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

struct NotificationContainerView: View {
    @ObservedObject var notificationService = NotificationService.shared
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var body: some View {
        VStack(spacing: 8) {
            ForEach(notificationService.notifications) { notification in
                NotificationView(notification: notification) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        notificationService.dismiss(notification.id)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom).padding(.bottom)
        .animation(
            .spring(response: 0.3, dampingFraction: 0.8), value: notificationService.notifications)
    }
}
