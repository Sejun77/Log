import SwiftUI

struct LoadingView: View {
    var body: some View {
        GeometryReader { geo in
            Image("LoadingBackground")
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .ignoresSafeArea()
        }
    }
}
