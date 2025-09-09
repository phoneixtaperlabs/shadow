import SwiftUI

struct NotiView: View {
    var title: String
    var baseSubtitle: String
    var initialCount: Int
    var buttonText: String
    var buttonAction: () -> Void

    @State private var count: Int
    @State private var timer: Timer?
    
    // 뷰가 초기화될 때 초기 카운트 값을 설정
    init(title: String, baseSubtitle: String, initialCount: Int, buttonText: String, buttonAction: @escaping () -> Void) {
        self.title = title
        self.baseSubtitle = baseSubtitle
        self.initialCount = initialCount
        self.buttonText = buttonText
        self.buttonAction = buttonAction
        self._count = State(initialValue: initialCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 17) {
            if let icon = AutopilotPlugin.shadowIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundColor(.orange)
            }
            
            Divider()
                .frame(height: 40) // 높이 조절
                .overlay(Color.backgroundHard.opacity(0.3))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(Color.text0)
                
                // 카운트다운 숫자를 포함한 부제목
                Text("\(baseSubtitle) \(count)..")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundColor(Color.text2)
            }

            Divider()
                .frame(height: 40) // 높이 조절
                .overlay(Color.backgroundHard.opacity(0.3))

            
            Button(action: buttonAction) {
                Text(buttonText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(buttonText == "Cancel" ? .text4 : .brandSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.backgroundHard)
        .cornerRadius(9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.borderSoft, lineWidth: 1)
        )
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if self.count > 0 {
                    print("Count --> \(count)")
                    self.count -= 1
                } else {
                    self.timer?.invalidate()
                }
            }
        }
        .onDisappear {
            print("NotiView is disappearing. Invalidating timer.")
            timer?.invalidate()
        }
    }
}
