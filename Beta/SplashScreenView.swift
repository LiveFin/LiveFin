//
//  SplashScreenView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/7/25.
//


import SwiftUI

struct SplashScreenView: View {
    @State private var isActive = false
    @State private var opacity = 0.0
    
    var body: some View {
        ZStack {
            if isActive {
                // Replace this with your main app view
                Text("Main App View")
                    .font(.headline)
            } else {
                // Splash Screen Content
                VStack {
                    Image("livefin-logo-light") // Use the name of your image asset
                        .resizable()
                        .frame(width: 128, height: 128)
                        .scaledToFit()
                        .opacity(opacity)
                    Text("LiveFin")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2)) // Darker gray
                        .opacity(opacity)
                    ProgressView() // Add a loading indicator
                        .padding(.top, 16)
                        .opacity(opacity)
                }
                .onAppear {
                    // Animate the opacity to fade in the content
                    withAnimation(.easeIn(duration: 1.0)) {
                        self.opacity = 1.0
                    }
                    // Simulate app loading
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        // Switch to the main app view after the delay
                        self.isActive = true
                    }
                }
            }
        }
    }
}

struct SplashScreenView_Previews: PreviewProvider {
    static var previews: some View {
        SplashScreenView()
    }
}
