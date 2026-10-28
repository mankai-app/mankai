//
//  SettingsHeaderView.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

struct SettingsHeaderView: View {
    let image: Image
    let color: Color
    let title: String
    let description: String

    var body: some View {
        Section {
            VStack {
                image.font(.title).foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 14).frame(width: 56, height: 56)
                            .foregroundColor(self.color)
                    )
                    .padding(.top, 12)
                Text(title).font(.title3).fontWeight(.semibold).padding(.top, 20)
                    .padding(.bottom, 2)
                Text(description).font(.subheadline).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16).padding(.horizontal, 4)
        } header: {
            Spacer(minLength: 0)
        }
    }
}
