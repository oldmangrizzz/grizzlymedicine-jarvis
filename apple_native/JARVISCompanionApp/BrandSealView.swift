import SwiftUI

struct BrandSealView: View {
    let size: CGFloat

    var body: some View {
        Image("GMRISeal")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("GMRI seal")
    }
}
