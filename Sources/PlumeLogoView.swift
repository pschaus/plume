import AppKit
import SwiftUI

struct PlumeLogoView: View {
    var size: CGFloat = 26

    var body: some View {
        if let logoURL = Bundle.main.url(forResource: "PlumeLogo", withExtension: "png"),
           let nsImage = NSImage(contentsOf: logoURL) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.365, green: 0.333, blue: 0.945),
                                Color(red: 0.310, green: 0.275, blue: 0.898),
                                Color(red: 0.263, green: 0.220, blue: 0.792)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size, height: size)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}
