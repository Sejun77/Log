import SwiftUI

// MARK: - Rest Overlay Screen

struct RestOverlayScreen: View {
    let title: String
    let remaining: Int
    let total: Int?  // use Int? so you can pass nil if you ever drop the bar
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(title)
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Text("\(remaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if let t = total, t > 0 {
                    let done = max(0, min(t, t - remaining))
                    ProgressView(value: Double(done), total: Double(t))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 240)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .transition(.opacity)
    }
}
