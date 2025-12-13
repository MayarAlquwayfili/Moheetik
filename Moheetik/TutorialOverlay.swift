//
//  TutorialOverlay.swift
//  Moheetik
//
//  Created by yumii on 11/12/2025.
//

import SwiftUI

/// Shared layout constants for tutorial visuals
let tutorialCardColor = Color("MPurple")
private let micSize: CGFloat = 50
private let mainSize: CGFloat = 80
private let bottomSpacing: CGFloat = 55
private let bottomPaddingTop: CGFloat = 20
private let bottomPaddingBottom: CGFloat = 20

struct FakeMicButton: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .opacity(0.7)
                .frame(width: 50, height: 50)
             
            Image(systemName: "mic.fill")
                .font(.system(size: 24))
                .foregroundColor(.white)
        }
      
    }
}
 
struct TutorialOverlay: View {
    
    @State private var currentStep = 1
    @AccessibilityFocusState private var isCardFocused: Bool
    
    var onDismiss: () -> Void
    
    private var isArabic: Bool { LocalizationManager.isArabic }
    private var tapHint: String {
        isArabic ? "اضغط مرتين للمتابعة" : "Double tap to continue"
    }
    private var stepTitle: String {
        switch currentStep {
        case 1:
            return isArabic ? "زر المسح" : "Main Scan Button"
        case 2:
            return isArabic ? "الميكروفون" : "Microphone Button"
        default:
            return isArabic ? "أنت جاهز!" : "You're All Set!"
        }
    }
    private var stepDescription: String {
        switch currentStep {
        case 1:
            return isArabic
            ? "اضغط هنا لبدء مسح المكان والتعرف على العوائق حولك."
            : "Tap to start scanning your surroundings and detect obstacles."
        case 2:
            return isArabic
            ? "يظهر بعد المسح. اضغط عليه لتطلب من التطبيق البحث عن شيء محدد."
            : "Appears after scanning. Tap to use voice commands to find specific objects."
        default:
            return isArabic ? "اضغط في أي مكان للبدء." : "Tap anywhere to start."
        }
    }
    
    var body: some View {
        ZStack {
            spotlightOverlay
                .ignoresSafeArea()
            selectionRingLayer
                .ignoresSafeArea()
            fakeMicLayer
                .ignoresSafeArea()

            VStack {
                TutorialCard(
                    title: stepTitle,
                    description: stepDescription
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(tapHint))
                .accessibilityFocused($isCardFocused)
                .padding(.horizontal)
                
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                if currentStep < 3 {
                    currentStep += 1
                } else {
                    onDismiss()
                }
            }
        }
        .accessibilityViewIsModal(true)
        .onAppear {
            isCardFocused = true
        }
        .onChange(of: currentStep) { _ in
            isCardFocused = true
        }
    }
    
    private var spotlightOverlay: some View {
        Color.black.opacity(0.7)
            .reverseMask {
                bottomBarLayout {
                    if currentStep == 2 {
                        Circle()
                            .frame(width: micSize, height: micSize)
                        
                    } else {
                        Color.clear
                            .frame(width: micSize, height: micSize)
                    }
                    
                    if currentStep == 1 {
                       Circle()
                         .frame(width: mainSize, height: mainSize)
                    } else {
                        Color.clear
                            .frame(width: mainSize, height: mainSize)
                    }
                    
                    Color.clear
                        .frame(width: micSize, height: micSize)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
    
    private var selectionRingLayer: some View {
        bottomBarLayout {
            Circle()
                .inset(by: 2)
                .stroke(Color.mPurple, lineWidth: 4)
                .blur(radius: 2)
                .frame(width: micSize, height: micSize)
                .opacity(currentStep == 2 ? 1 : 0)
            
            Circle()
                .inset(by: 2)
                .stroke(Color.mPurple, lineWidth: 4)
                .blur(radius: 2)
                .frame(width: mainSize, height: mainSize)
                .opacity(currentStep == 1 ? 1 : 0)
            
            Color.clear
                .frame(width: micSize, height: micSize)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    
    private var fakeMicLayer: some View {
        bottomBarLayout {
            FakeMicButton()
                .frame(width: micSize, height: micSize)
                .opacity(currentStep == 2 ? 1 : 0)
                .accessibilityHidden(true)
            
            Color.clear
                .frame(width: mainSize, height: mainSize)
            
            Color.clear
                .frame(width: micSize, height: micSize)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    
    /// Mirror FullCameraView bottom bar positioning
    @ViewBuilder
    private func bottomBarLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer()
            VStack {
                HStack(spacing: bottomSpacing) {
                    content()
                }
                .padding(.top, bottomPaddingTop)
                .padding(.bottom, bottomPaddingBottom)
            }
        }
        .ignoresSafeArea()
    }
    
}

extension View {
    /// Create inverted mask to punch holes in a layer
    @ViewBuilder func reverseMask<Mask: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ mask: () -> Mask
    ) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: alignment) {
                    mask()
                        .blendMode(.destinationOut)
                }
        }
    }
}

struct TutorialCard: View {
    let title: String
    let description: String
    
    var body: some View {
        /// Show step title and description together
        VStack(spacing: 8) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
            Text(description)
                .font(.callout)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .padding(20)
        .background(tutorialCardColor.opacity(0.8))
        .cornerRadius(10)
        .padding(.horizontal, 40)
    }
}

#Preview {
    ZStack {
        Color.gray
            .ignoresSafeArea()
            .overlay(
                Text("Camera Feed Placeholder")
                    .foregroundColor(.white.opacity(0.3))
            )
        
        TutorialOverlay(onDismiss: {
            print("Tutorial Finished")
        })
    }
}
