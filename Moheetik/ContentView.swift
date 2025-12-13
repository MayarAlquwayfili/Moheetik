//
//  ContentView.swift
//  Moheetik
//
//  Created by yumii on 30/11/2025.
//

import SwiftUI
import UIKit

struct ContentView: View {
    
    @AppStorage("hasSeenTutorial") var hasSeenTutorial: Bool = false
    @State private var isMicrophoneHelpActive: Bool = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FullCameraView()
                .accessibilityHidden(!hasSeenTutorial)
            
        }
        .onAppear {
            hasSeenTutorial = false
        }
        .overlay(
            Group {
                if !hasSeenTutorial {
                    TutorialOverlay(onDismiss: {
                        withAnimation {
                            hasSeenTutorial = true
                        }
                    })
                    .accessibilityViewIsModal(true)
                }
            }
        )
    }
}

private struct ModalAccessibilityView: UIViewRepresentable {
    let isModal: Bool
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isAccessibilityElement = false
        view.accessibilityViewIsModal = isModal
        view.isHidden = true
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityViewIsModal = isModal
    }
}

extension View {
    func accessibilityViewIsModal(_ isModal: Bool) -> some View {
        background(
            ModalAccessibilityView(isModal: isModal)
                .allowsHitTesting(false)
        )
    }
}

#Preview {
    ContentView()
}
