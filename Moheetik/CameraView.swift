//
//  CameraView.swift
//  Moheetik
//
//  Created by yumii on 30/11/2025.
//

import SwiftUI
import AVFoundation
import Combine
import Vision
import Speech
import CoreML
import ARKit
 

enum CameraState: Equatable, Sendable {
    case idle
    case speaking
    case recording
}

struct ColorFingerprint: Sendable {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    
    static let empty = ColorFingerprint(r: 0, g: 0, b: 0)
    
    func distance(to other: ColorFingerprint) -> CGFloat {
        let dr = r - other.r
        let dg = g - other.g
        let db = b - other.b
        return sqrt(dr*dr + dg*dg + db*db) / sqrt(3.0)
    }
}

struct DetectedObject: Identifiable, Sendable {
    let id = UUID()
    var label: String
    let rawLabel: String
    let confidence: Float
    let boundingBox: CGRect
    var color: Color
    var fingerprint: ColorFingerprint = .empty
}
 

@MainActor
class CameraViewModel: NSObject, ObservableObject {
    @Published var state: CameraState = .idle
    @Published var isFrontCamera: Bool = false
    @Published var loadingText: String = ""
    @Published var detectedObjects: [DetectedObject] = []
    @Published var targetObject: String? = nil
    @Published var speechManager = SpeechManager()
    @Published var lockedAnchorID: UUID? = nil
    @Published var targetDistance: Float? = nil
    @Published var isAnchorVisible: Bool = false
    @Published var anchorScreenPosition: CGPoint? = nil
    @Published var isVisuallyConfirmed: Bool = false
    var lastKnownBoundingBoxSize: CGSize = CGSize(width: 0.15, height: 0.2)
    var lockedAnchorLabel: String? = nil
    var anchorLabels: [UUID: String] = [:]
    var currentYOLODetections: [CGRect] = []
    var currentYOLOClassNames: [String] = []
    private let navigationManager = NavigationManager()
    var lastScreenSize: CGSize = .zero
    private var visualConfirmationFailCount: Int = 0
    private let maxFailFramesBeforeLost: Int = 5
    private var lastConfirmedTime: Date = .distantPast
    private var lastSpokenText: String = ""
    private let synthesizer = AVSpeechSynthesizer()
    private var nextStateAfterSpeaking: CameraState = .idle
    private var hasAnnouncedArrival: Bool = false
    private var hasAnnouncedLost: Bool = false
    private var lostTimestamp: Date? = nil
    private var lastGuidanceTime: Date? = nil
    private var wasReacquired: Bool = false
    /// Vision request for YOLOv3 object detection.
    var yoloRequest: VNCoreMLRequest?
    
    /// Vision request for MoheetikModel object detection.
    var moheetikRequest: VNCoreMLRequest?
    
    /// Callback to reset ARSession when needed.
    var onSessionReset: (() -> Void)?
    
    override init() {
        super.init()
        synthesizer.delegate = self
        setupAudioSession()
        Task(priority: .high) { await setupModel() }
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("🔊 Audio Error: \(error)") }
    }
    
    func resetAudioSessionForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("🔊 Reset Audio Error: \(error)") }
    }
    /// Loads both YOLOv3 and MoheetikModel for multi-model detection.
    private func setupModel() async {
        let yoloTask = Task.detached(priority: .userInitiated) { () -> VNCoreMLModel? in
            do {
                let config = MLModelConfiguration()
                let model = try await YOLOv3(configuration: config).model
                return try VNCoreMLModel(for: model)
            } catch {
                print("❌ YOLOv3 load error: \(error)")
                return nil
            }
        }
        
        let moheetikTask = Task.detached(priority: .userInitiated) { () -> VNCoreMLModel? in
            do {
                let config = MLModelConfiguration()
                let model = try await MoheetikModel(configuration: config).model
                return try VNCoreMLModel(for: model)
            } catch {
                print("❌ MoheetikModel load error: \(error)")
                return nil
            }
        }
        
        if let yoloModel = await yoloTask.value {
            self.yoloRequest = VNCoreMLRequest(model: yoloModel)
            self.yoloRequest?.imageCropAndScaleOption = .scaleFill
            print("✅ YOLOv3 Loaded!")
        }
        
        if let moheetikModel = await moheetikTask.value {
            self.moheetikRequest = VNCoreMLRequest(model: moheetikModel)
            self.moheetikRequest?.imageCropAndScaleOption = .scaleFill
            print("✅ MoheetikModel Loaded!")
        }
    }
    
    func mainButtonTapped() {
        state == .idle ? startSequence() : stopRecording()
    }
    
    func toggleMicrophone() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if speechManager.isRecording {
            speechManager.stopRecording()
            resetAudioSessionForPlayback()
            
            let spokenText = speechManager.detectedText.lowercased()
            print("User said: \(spokenText)")
            
            if let target = extractTargetFromSpeech(text: spokenText) {
                setTarget(target)
            } else {
                speak(text: "Could not understand. Try 'Chair 1'.", force: true)
            }
        } else {
            synthesizer.stopSpeaking(at: .immediate)
            speechManager.detectedText = ""
            speechManager.startRecording()
        }
    }

    /// Extracts target object name from spoken text with synonym support.
    private func extractTargetFromSpeech(text: String) -> String? {
        // YOLOv3 classes
        let yoloObjects = [
            "person", "bicycle", "car", "motorbike", "aeroplane", "bus", "train", "truck", "boat",
            "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
            "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
            "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
            "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
            "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
            "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
            "chair", "sofa", "pottedplant", "bed", "diningtable", "toilet", "tvmonitor", "laptop",
            "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
            "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
            "tv", "phone", "mobile", "table", "plant"
        ]
        
        // MoheetikModel classes
        let moheetikObjects = [
            "door", "stairs", "elevator", "elevator_button", "exit", "entrance",
            "handrail", "ramp", "crossing", "sidewalk"
        ]
        
        // Synonyms: spoken word → model class name
        let synonyms: [String: String] = [
            "lift": "elevator",
            "steps": "stairs",
            "staircase": "stairs",
            "button": "elevator_button"
        ]
        
        let knownObjects = yoloObjects + moheetikObjects + Array(synonyms.keys)
        
        for obj in knownObjects {
            if text.contains(obj) {
                var numberSuffix = ""
                if text.contains("one") || text.contains("1") { numberSuffix = " 1" }
                else if text.contains("two") || text.contains("2") { numberSuffix = " 2" }
                else if text.contains("three") || text.contains("3") { numberSuffix = " 3" }
                
                // Apply synonym mapping first
                var cleanName = synonyms[obj] ?? obj
                
                // Then apply legacy mappings
                if cleanName == "table" { cleanName = "diningtable" }
                if cleanName == "tv" { cleanName = "tvmonitor" }
                if cleanName == "phone" || cleanName == "mobile" { cleanName = "cell phone" }
                if cleanName == "plant" { cleanName = "pottedplant" }
                if cleanName == "sofa" { cleanName = "couch" }
                
                return cleanName.capitalized + numberSuffix
            }
              }
              return nil
          }
      
    private func setTarget(_ name: String) {
        lockedAnchorID = nil
        targetDistance = nil
        isAnchorVisible = false
        anchorScreenPosition = nil
        lockedAnchorLabel = name
        hasAnnouncedArrival = false
        hasAnnouncedLost = false
        lostTimestamp = nil
        wasReacquired = false
        
        targetObject = name
        speak(text: "Searching for \(name)", force: true)
    }
     
    private func startSequence() {
        nextStateAfterSpeaking = .recording
        loadingText = "Starting... Hold steady"
        resetAllTrackingState()
        onSessionReset?()
        
        withAnimation { state = .speaking }
        
        // Use speakFinal for startup (bypasses state guard)
        speakFinal(text: loadingText)
        
        // FALLBACK: Force transition after 1.5 seconds if speech fails/muted
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking && self.nextStateAfterSpeaking == .recording {
                withAnimation(.spring()) { self.state = .recording }
            }
        }
    }
    
    private func stopRecording() {
        // CRITICAL: Stop speech immediately as FIRST action
        synthesizer.stopSpeaking(at: .immediate)
        
        // Clear speech state to prevent ghost speech
        lastSpokenText = ""
        
        // Set state to idle FIRST to block any pending speak() calls
        nextStateAfterSpeaking = .idle
        loadingText = "Finished"
        
        // Reset all tracking (also clears lastSpokenText)
        resetAllTrackingState()
        onSessionReset?()
        
        // Now transition to speaking state for final announcement
        withAnimation { state = .speaking }
        speakFinal(text: loadingText)
        
        // FALLBACK: Force transition after 1.5 seconds if speech fails/muted
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking && self.nextStateAfterSpeaking == .idle {
                withAnimation(.spring()) { self.state = .idle }
            }
        }
    }
    
    /// Special speak function for final announcements (ignores state guard)
    private func speakFinal(text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }
    
    private func resetAllTrackingState() {
        targetObject = nil
        detectedObjects = []
        lockedAnchorID = nil
        targetDistance = nil
        isAnchorVisible = false
        isVisuallyConfirmed = false
        anchorScreenPosition = nil
        lockedAnchorLabel = nil
        anchorLabels.removeAll()
        currentYOLODetections = []
        currentYOLOClassNames = []
        hasAnnouncedArrival = false
        hasAnnouncedLost = false
        lostTimestamp = nil
        lastGuidanceTime = nil
        wasReacquired = false
        lastSpokenText = ""
        visualConfirmationFailCount = 0
        lastConfirmedTime = .distantPast
        navigationManager.reset()
    }
    
    
    func anchorCreated(id: UUID, boundingBoxSize: CGSize) {
        lockedAnchorID = id
        lastKnownBoundingBoxSize = boundingBoxSize
        hasAnnouncedLost = false
        lostTimestamp = nil
        lastGuidanceTime = nil
        
        
        if let label = lockedAnchorLabel {
            anchorLabels[id] = label
        }
        
        if let target = targetObject {
            speak(text: "Locked onto \(target)", force: true)
        }
    }
    
    func getLabelForAnchor(id: UUID) -> String? {
        return anchorLabels[id]
    }
    
    func updateYOLODetections(boxes: [CGRect], classNames: [String]) {
        currentYOLODetections = boxes
        currentYOLOClassNames = classNames
    }
    
    func checkVisualConfirmation(anchorScreenPosition: CGPoint, screenSize: CGSize, targetClass: String) -> Bool {
        if currentYOLODetections.isEmpty {
            return true
        }
        
        let normalizedX = anchorScreenPosition.x / screenSize.width
        let normalizedY = 1 - (anchorScreenPosition.y / screenSize.height)
        let anchorPoint = CGPoint(x: normalizedX, y: normalizedY)
        
        let targetBase = targetClass.components(separatedBy: " ").first?.lowercased() ?? ""
        
        for (index, box) in currentYOLODetections.enumerated() {
            let expandedBox = box.insetBy(dx: -0.1, dy: -0.1)
            
            if expandedBox.contains(anchorPoint) {
                let detectedClass = currentYOLOClassNames[safe: index]?.lowercased() ?? ""
                if detectedClass.contains(targetBase) || targetBase.contains(detectedClass) {
                    return true
                }
            }
        }
        
        for (index, _) in currentYOLODetections.enumerated() {
            let detectedClass = currentYOLOClassNames[safe: index]?.lowercased() ?? ""
            if detectedClass.contains(targetBase) || targetBase.contains(detectedClass) {
                let box = currentYOLODetections[index]
                let boxCenter = CGPoint(x: box.midX, y: box.midY)
                let distance = hypot(anchorPoint.x - boxCenter.x, anchorPoint.y - boxCenter.y)
                if distance < 0.3 {
                    return true
                }
            }
        }
        
        return false
    }
    
    func updateAnchorTracking(
        distance: Float,
        screenPosition: CGPoint?,
        isVisible: Bool,
        screenSize: CGSize = .zero,
        userPosition: SIMD3<Float>? = nil,
        targetPosition: SIMD3<Float>? = nil,
        cameraForward: SIMD3<Float>? = nil
    ) {
        
        guard state == .recording else { return }
        
        self.targetDistance = distance
        self.anchorScreenPosition = screenPosition
        self.lastScreenSize = screenSize
        
        guard let target = targetObject else { return }
        
        let closeRangeOverride = distance < 1.5
        
        var rawConfirmed = false
        if isVisible, let pos = screenPosition {
            rawConfirmed = checkVisualConfirmation(
                anchorScreenPosition: pos,
                screenSize: screenSize,
                targetClass: target
            )
        }
        if closeRangeOverride && isVisible {
            visualConfirmationFailCount = 0
            lastConfirmedTime = Date()
            isVisuallyConfirmed = true
        } else if rawConfirmed || isVisible {
            visualConfirmationFailCount = 0
            lastConfirmedTime = Date()
            isVisuallyConfirmed = true
        } else {
            visualConfirmationFailCount += 1
            if visualConfirmationFailCount > maxFailFramesBeforeLost {
                isVisuallyConfirmed = false
            }
        }
        
        let wasAnchorVisible = self.isAnchorVisible
        self.isAnchorVisible = isVisible
        let effectivelyVisible = (isVisible && isVisuallyConfirmed) || closeRangeOverride
        
        
        if effectivelyVisible && !wasAnchorVisible && hasAnnouncedLost {
            hasAnnouncedLost = false
            lostTimestamp = nil
            lastGuidanceTime = nil
            visualConfirmationFailCount = 0
            navigationManager.reset()
            let msg = "Found \(target) again"
            lastSpokenText = msg
            speak(text: msg, force: true)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        
        if distance < 0.8 && isVisible && !hasAnnouncedArrival {
            hasAnnouncedArrival = true
            let msg = "You have arrived at \(target). Scanning finished."
            lastSpokenText = msg
            speak(text: msg, force: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.stopRecording()
            }
            return
        }
        
        let hasAnchorPosition = userPosition != nil && targetPosition != nil
        
        if !effectivelyVisible && !isVisible && hasAnchorPosition && !hasAnnouncedArrival {
            if let userPos = userPosition, let targetPos = targetPosition, screenSize != .zero {
                if let guidance = navigationManager.getGuidance(
                    userPosition: userPos,
                    targetPosition: targetPos,
                    screenPoint: nil,
                    screenSize: screenSize,
                    cameraForward: cameraForward
                ) {
                    speak(text: guidance, force: false)
                }
            }
            
            triggerDistanceHaptic(distance: distance)
        } else if !effectivelyVisible && !hasAnnouncedArrival {
            if visualConfirmationFailCount > maxFailFramesBeforeLost {
                handleTargetNotVisible(target: target)
            }
        } else if effectivelyVisible && !hasAnnouncedArrival {
            hasAnnouncedLost = false
            lostTimestamp = nil
            lastGuidanceTime = nil
            
            if let userPos = userPosition, let targetPos = targetPosition, screenSize != .zero {
                if let guidance = navigationManager.getGuidance(
                    userPosition: userPos,
                    targetPosition: targetPos,
                    screenPoint: screenPosition,
                    screenSize: screenSize,
                    cameraForward: cameraForward
                ) {
                    speak(text: guidance, force: false)
                }
            }
            
            triggerDistanceHaptic(distance: distance)
        }
    }
    
    private func handleTargetNotVisible(target: String) {
        let now = Date()
        
        if !hasAnnouncedLost {
            hasAnnouncedLost = true
            lostTimestamp = now
            lastGuidanceTime = now
            let msg = "Target lost"
            lastSpokenText = msg
            speak(text: msg, force: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else if let lastGuidance = lastGuidanceTime, now.timeIntervalSince(lastGuidance) > 4.0 {
            lastGuidanceTime = now
            let msg = "Please turn around to find \(target)"
            lastSpokenText = msg
            speak(text: msg, force: false)
        }
    }
    
    func updateDetections(_ objects: [DetectedObject]) {
        self.detectedObjects = objects

        if targetObject != nil && lockedAnchorID != nil {
            return
        }
    
        if targetObject == nil {
            let labels = objects.map { $0.label }.sorted().joined(separator: ", ")
            if !labels.isEmpty && labels != lastSpokenText {
                lastSpokenText = labels
                speak(text: labels, force: false)
            }
        }
    }
    
    func notifyTargetLost() {
            let warning = "Target lost. Move back."
            if lastSpokenText != warning {
                lastSpokenText = warning
                speak(text: warning, force: true)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            self.detectedObjects = []
        }
        
        private func triggerHaptic(size: CGFloat) {
            if size > 0.3 {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } else if size > 0.05 {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
            }
        }
    
    private func triggerDistanceHaptic(distance: Float) {
        if distance < 1.0 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else if distance < 2.0 {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        } else if distance < 3.0 {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        }
    
    /// Speaks text only during active recording session.
    private func speak(text: String, force: Bool) {
        // STRICT GUARD: Only speak during active recording
        guard state == .recording else { return }
        guard !speechManager.isRecording else { return }
        
        if force {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        } else {
            if synthesizer.isSpeaking { return }
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }
}


extension CameraViewModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.state == .speaking {
                withAnimation(.spring()) { self.state = self.nextStateAfterSpeaking }
            }
        }
    }
}


struct DetectionOverlay: View {
    let objects: [DetectedObject]
    let screenSize: GeometryProxy
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(objects) { object in
                let rect = calculateScreenRect(bbox: object.boundingBox, in: screenSize.size)
                Rectangle()
                    .path(in: rect)
                    .stroke(object.color, lineWidth: 3)
                
                Text(object.label)
                    .font(.caption.bold())
                    .padding(4)
                    .background(object.color)
                    .foregroundColor(.black)
                    .cornerRadius(4)
                    .offset(x: rect.minX, y: rect.minY - 25)
            }
        }
    }
    
    private func calculateScreenRect(bbox: CGRect, in size: CGSize) -> CGRect {
        let w = bbox.width * size.width
        let h = bbox.height * size.height
        let x = bbox.minX * size.width
        let y = (1 - bbox.maxY) * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct FullCameraView: View {
    @StateObject private var vm = CameraViewModel()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                ARCameraView(vm: vm).ignoresSafeArea()
                
                if vm.state == .recording {
                    DetectionOverlay(objects: vm.detectedObjects, screenSize: geometry)
                        .ignoresSafeArea()
                }
                
                VStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.7))
                        .frame(height: 60)
                        .ignoresSafeArea(.all, edges: .top)
                    
                    if vm.speechManager.isRecording {
                        Text(vm.speechManager.detectedText)
                            .font(.title3)
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.top, 20)
                    } else if let target = vm.targetObject {
                        Text("Looking for: \(target)")
                            .font(.headline)
                            .padding(8)
                            .background(Color.mGreen)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding(.top, 20)
                    }
                    
                    Spacer()
                    
                    ZStack(alignment: .bottom) {
                        VStack {
                            HStack(spacing: 55) {
                                Button(action: { vm.toggleMicrophone() }) {
                                    ZStack {
                                        Circle()
                                            .fill(vm.speechManager.isRecording ? Color.red : Color.black)
                                            .opacity(0.7)
                                            .frame(width: 50, height: 50)
                                        Image(systemName: vm.speechManager.isRecording ? "waveform" : "mic.fill")
                                            .font(.system(size: 24))
                                            .foregroundColor(.white)
                                    }
                                }
                                .disabled(vm.state == .idle)
                                .opacity(vm.state == .idle ? 0 : 1)
                                
                                Button(action: { vm.mainButtonTapped() }) {
                                    ZStack {
                                        Circle().fill(Color.black).opacity(0.7).frame(width: 80, height: 80)
                                        RoundedRectangle(cornerRadius: vm.state == .recording ? 10 : 35)
                                            .fill(vm.state == .recording ? Color.red : Color.white)
                                            .frame(width: vm.state == .recording ? 40 : 70, height: vm.state == .recording ? 40 : 70)
                                    }
                                }
                                
                                ZStack { Circle().fill(Color.black).frame(width: 50, height: 50) }
                                    .opacity(0)
                                    .accessibilityHidden(true)
                            }
                            .padding(.top, 20)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity)
                            .background(Rectangle().fill(Color.black.opacity(0.7)).ignoresSafeArea(edges: .bottom))
                        }
                    }
                }
                
                if vm.state == .speaking {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        Color.black.opacity(0.5)
                        VStack(spacing: 20) {
                            ProgressView().tint(.white).scaleEffect(1.5)
                            Text(vm.loadingText).font(.title3.bold()).foregroundColor(.white)
                        }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .animation(.default, value: vm.state)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

#Preview { FullCameraView() }
