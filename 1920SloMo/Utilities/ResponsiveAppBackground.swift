import SwiftUI

struct ResponsiveAppBackground: View {
    var body: some View {
        GeometryReader { proxy in
            Image(proxy.size.height >= proxy.size.width
                  ? "AppBackgroundPortrait"
                  : "AppBackgroundLandscape")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
