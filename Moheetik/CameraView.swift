//
//  CameraView.swift
//  Moheetik
//
//  Created by yumii on 30/11/2025.
//

import SwiftUI
import UIKit
import AVFoundation
import Combine
import Vision
import Speech
import CoreML
import ARKit
 

/// High-level camera states for the app flow.
enum CameraState: Equatable, Sendable {
    case idle
    case speaking
    case recording
}

/// Simple RGB fingerprint for re-identifying objects.
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

/// Holds one detected object's info for overlays and speech.
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
/// Main brain that controls camera, AR, and speech.
class CameraViewModel: NSObject, ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    /// Last time we announced a specific label.
    private var lastAnnouncementTime: [String: Date] = [:]
    /// Current camera state for UI.
    @Published var state: CameraState = .idle
    /// Unused flag for possible front camera switch.
    @Published var isFrontCamera: Bool = false
    /// Loading message while preparing.
    @Published var loadingText: String = ""
    /// Objects currently drawn on screen.
    @Published var detectedObjects: [DetectedObject] = []
    /// The target object name chosen by voice.
    @Published var targetObject: String? = nil
    /// Speech manager handling mic and STT.
    @Published var speechManager = SpeechManager.shared
    /// Locked anchor ID if one exists.
    @Published var lockedAnchorID: UUID? = nil
    /// Current distance to locked target.
    @Published var targetDistance: Float? = nil
    /// True when AR anchor is visible.
    @Published var isAnchorVisible: Bool = false
    /// Screen position of the anchor.
    @Published var anchorScreenPosition: CGPoint? = nil
    /// True when vision confirms the anchor.
    @Published var isVisuallyConfirmed: Bool = false
    /// Last known box size for locked anchor.
    var lastKnownBoundingBoxSize: CGSize = CGSize(width: 0.15, height: 0.2)
    /// Display label for locked anchor.
    var lockedAnchorLabel: String? = nil
    /// Mapping of anchor IDs to labels.
    var anchorLabels: [UUID: String] = [:]
    /// Raw YOLO boxes for visual confirmation.
    var currentYOLODetections: [CGRect] = []
    /// Raw YOLO class names for confirmation.
    var currentYOLOClassNames: [String] = []
    /// Helper that builds guidance phrases.
    private let navigationManager = NavigationManager()
    /// Last screen size for overlay math.
    var lastScreenSize: CGSize = .zero
    /// Tracks how many frames lost confirmation.
    private var visualConfirmationFailCount: Int = 0
    /// Max frames before declaring lost.
    private let maxFailFramesBeforeLost: Int = 60
    /// Last time anchor was confirmed.
    private var lastConfirmedTime: Date = .distantPast
    /// Last phrase spoken to avoid repeats.
    private var lastSpokenText: String = ""
    /// Last announced object list.
    private var lastAnnouncedObjects: String = ""
    /// Timestamp when lock was achieved to gate arrival speech.
    private var lockTime: Date? = nil
    /// TTS engine for announcements.
    private let synthesizer = AVSpeechSynthesizer()
    /// Player for UI sound effects (e.g., mic toggle).
    private var audioPlayer: AVAudioPlayer?
    /// Next state after a speaking phase.
    private var nextStateAfterSpeaking: CameraState = .idle
    /// Has arrival been announced once.
    private var hasAnnouncedArrival: Bool = false
    /// Has loss been announced once.
    private var hasAnnouncedLost: Bool = false
    /// When the target was lost.
    private var lostTimestamp: Date? = nil
    /// Last time we gave guidance.
    private var lastGuidanceTime: Date? = nil
    /// Whether we re-found the target.
    private var wasReacquired: Bool = false
    /// Request to run ML immediately.
    @Published var requestImmediateInference: Bool = false

    /// CoreML YOLO request.
    var yoloRequest: VNCoreMLRequest?
    /// Custom model request.
    var moheetikRequest: VNCoreMLRequest?
    /// Callback to reset AR session.
    var onSessionReset: (() -> Void)?
    
    /// Sets up audio, language, and ML models.
    override init() {
        super.init()
        LocalizationManager.refreshLanguage()
        synthesizer.delegate = self
        setupAudioSession()
        Task(priority: .high) { await setupModel() }
        speechManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    /// Prepares the audio session for recording and playback.
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("🔊 Audio Error: \(error)") }
    }
    
    /// Switches audio session to playback after recording.
    func resetAudioSessionForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("🔊 Reset Audio Error: \(error)") }
    }

    func playSound() {
        // Configure session for playback
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // Try to find the file
        let soundName = "mic_button_press"
        let soundExt = "mp3"
        var soundURL = Bundle.main.url(forResource: soundName, withExtension: soundExt)
        if soundURL == nil {
            soundURL = Bundle.main.url(forResource: soundName, withExtension: soundExt, subdirectory: "Sounds")
        }

        guard let url = soundURL else {
            print("🔊 Error: Sound file '\(soundName).\(soundExt)' not found in Bundle.")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("🔊 Audio Player Error: \(error)")
        }
    }
    /// Both YOLOv3 and MoheetikModel.
    /// Loads the ML models asynchronously.
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
    
    /// Handles the main start/stop UI button.
    func mainButtonTapped() {
        synthesizer.stopSpeaking(at: .immediate)
        state == .idle ? startSequence() : stopRecording()
    }
    
    /// Starts or stops the microphone for voice commands.
    func toggleMicrophone() {
        synthesizer.stopSpeaking(at: .immediate)
        LocalizationManager.refreshLanguage()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        playSound()
        if speechManager.isRecording {
            speechManager.stopRecording()
            processRecordedText()
        } else {
            synthesizer.stopSpeaking(at: .immediate)
            detectedObjects = []
            speechManager.detectedText = ""
            synthesizer.stopSpeaking(at: .immediate)
            speechManager.startRecording()
        }
    }

    /// Target object name from spoken text.
    /// Pulls a target object name from spoken text.
    private func extractTargetFromSpeech(text: String) -> String? {
        if LocalizationManager.isArabic || LocalizationManager.containsArabicCharacters(text) {
            if let arabicMatch = LocalizationManager.matchArabicCommand(text) {
                let numberSuffix = LocalizationManager.extractNumber(from: text).map { " \($0)" } ?? ""
                return arabicMatch.capitalized + numberSuffix
            }
        }
        
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
        
        // Spoken word → model class name
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
                
                var cleanName = synonyms[obj] ?? obj
                
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

    private func processRecordedText() {
        // 1. Stop playback & Get text
        resetAudioSessionForPlayback()
        let spokenText = speechManager.detectedText.lowercased()
        print("User said: \(spokenText)")
        
        // 2. Check Dictionary
        if let target = extractTargetFromSpeech(text: spokenText) {
            // Found! Start Search.
            setTarget(target)
            lastAnnouncementTime.removeAll()
            requestImmediateInference = true
        } else {
            // Not Found! Speak Error.
            let errorMsg = LocalizationManager.localizeStatus("Could not understand. Try 'Chair 1'.")
            speak(text: errorMsg, force: true)
        }
    }
      
    /// Stores the chosen target and announces search.
    private func setTarget(_ name: String) {
        lockedAnchorID = nil
        targetDistance = nil
        isAnchorVisible = false
        anchorScreenPosition = nil
        lockedAnchorLabel = LocalizationManager.localizeForSpeech(name)
        hasAnnouncedArrival = false
        hasAnnouncedLost = false
        lostTimestamp = nil
        wasReacquired = false
        lastAnnouncedObjects = ""
        
        targetObject = name
        speak(text: "Searching for \(name)", force: true)
    }
     
    /// Starts scanning: resets, speaks loading, then begins recording.
    private func startSequence() {
        nextStateAfterSpeaking = .recording
        loadingText = LocalizationManager.localizeStatus("Starting... Hold steady")
        resetAllTrackingState()
        onSessionReset?()
        withAnimation { state = .speaking }
        speakFinal(text: loadingText)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking && self.nextStateAfterSpeaking == .recording {
                withAnimation(.spring()) { self.state = .recording }
            }
        }
    }
    
    /// Stops scanning: resets tracking and optionally speaks finished.
    private func stopRecording(shouldSpeak: Bool = true) {
        synthesizer.stopSpeaking(at: .immediate)
        lastSpokenText = ""
        nextStateAfterSpeaking = .idle
        loadingText = LocalizationManager.localizeStatus("Finished")
        resetAllTrackingState()
        onSessionReset?()
        withAnimation { state = .speaking }
        if shouldSpeak {
            speakFinal(text: loadingText)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking && self.nextStateAfterSpeaking == .idle {
                withAnimation(.spring()) { self.state = .idle }
            }
        }
    }
    
    /// Speaks a message during the speaking state.
    private func speakFinal(text: String) {
        let localized = LocalizationManager.localizeOutput(text)
        
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: localized)
        } else {
            let utterance = makeUtterance(localized)
            synthesizer.speak(utterance)
        }
    }

    /// Stops current speech and clears overlays immediately.
    func stopSpeakingImmediate() {
        synthesizer.stopSpeaking(at: .immediate)
        detectedObjects = []
    }
    
    /// Clears all target and detection state.
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
        lastAnnouncedObjects = ""
        visualConfirmationFailCount = 0
        lastConfirmedTime = .distantPast
        navigationManager.reset()
    }
    
    
    /// Called when an AR anchor is successfully placed.
    func anchorCreated(id: UUID, boundingBoxSize: CGSize) {
        lockedAnchorID = id
        lastKnownBoundingBoxSize = boundingBoxSize
        hasAnnouncedLost = false
        lostTimestamp = nil
        lastGuidanceTime = nil
        lockTime = Date()
        
        
        if let label = lockedAnchorLabel {
            anchorLabels[id] = label
        }
        
        if let target = targetObject {
            speak(text: "Locked onto \(target)", force: true)
        }
    }
    
    /// Returns the display label for a locked anchor.
    func getLabelForAnchor(id: UUID) -> String? {
        return anchorLabels[id]
    }
    
    /// Saves raw YOLO detections for confirmation logic.
    func updateYOLODetections(boxes: [CGRect], classNames: [String]) {
        currentYOLODetections = boxes
        currentYOLOClassNames = classNames
    }
    
    /// Checks if YOLO detections align with the anchor position.
    func checkVisualConfirmation(anchorScreenPosition: CGPoint, screenSize: CGSize, targetClass: String) -> Bool {
        if currentYOLODetections.isEmpty {
            return true
        }
        
        let normalizedX = anchorScreenPosition.x / screenSize.width
        let normalizedY = 1 - (anchorScreenPosition.y / screenSize.height)
        let anchorPoint = CGPoint(x: normalizedX, y: normalizedY)
        
        let targetBase = targetClass.components(separatedBy: " ").first?.lowercased() ?? ""
        
        for (index, box) in currentYOLODetections.enumerated() {
            let expandedBox = box.insetBy(dx: -0.2, dy: -0.2)
            
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
                if distance < 0.5 {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Updates distance, visibility, and guidance for the locked target.
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
        let closeRangeTrust = distance < 2.0
        
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
        } else if closeRangeTrust && isVisible {
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
        
        if distance < 0.4 && isVisible && !hasAnnouncedArrival {
            guard let lockTime = lockTime, Date().timeIntervalSince(lockTime) > 2.0 else { return }
            hasAnnouncedArrival = true
            let msg = "You have arrived at \(target). Scanning finished."
            lastSpokenText = msg
            speak(text: msg, force: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.stopRecording(shouldSpeak: false)
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
    
    /// Speaks guidance when the target is lost from view.
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
    
    /// Updates overlays and speaks object names when no target is active.
    func updateDetections(_ objects: [DetectedObject]) {
        // 1. ABSOLUTE AGGRESSIVE SILENCE GUARD
        // If mic is recording, kill any speech immediately, clear visual objects, and exit.
        if speechManager.isRecording {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            if !self.detectedObjects.isEmpty { self.detectedObjects = [] }
            return
        }
        
        // 2. State Guard: Only process if we are actually recording video
        guard state == .recording else { return }
        let localizedObjects = localizeObjectsIfNeeded(objects)
        self.detectedObjects = localizedObjects

        if targetObject != nil && lockedAnchorID != nil {
            return
        }

        let labels = localizedObjects.map { $0.label }.sorted().joined(separator: ", ")
        guard !labels.isEmpty else { return }

        // 1. Strict Time Check (10 seconds silence required between same/similar objects)
        let now = Date()
        if let lastTime = lastAnnouncementTime[labels], now.timeIntervalSince(lastTime) < 10.0 { return }

        // 2. Similarity Check (The "Shake" Fix)
        // If the new list contains the old one or vice versa (e.g., "Chair" vs "Chair, Table"), TREAT AS SAME.
        if labels.contains(lastAnnouncedObjects) || lastAnnouncedObjects.contains(labels) {
            // Just update timestamp to keep it silent, DO NOT SPEAK
            lastAnnouncementTime[labels] = now
            return
        }

        // 3. Speak only if truly new
        lastAnnouncementTime[labels] = now
        lastAnnouncedObjects = labels
        speak(text: labels, force: false)
    }
    
    /// Forces a "target lost" warning and clears overlays.
    func notifyTargetLost() {
            let warning = "Target lost. Move back."
            if lastSpokenText != warning {
                lastSpokenText = warning
                speak(text: warning, force: true)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            self.detectedObjects = []
        }
        
        /// Haptic feedback based on object size on screen.
        private func triggerHaptic(size: CGFloat) {
            if size > 0.3 {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } else if size > 0.05 {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
            }
        }
    
    /// Haptic feedback based on distance to the anchor.
    private func triggerDistanceHaptic(distance: Float) {
        if distance < 1.0 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else if distance < 2.0 {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        } else if distance < 3.0 {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        }
    
    
    /// Speaks a message if not currently recording speech input.
    private func speak(text: String, force: Bool, forceArabic: Bool = false) {
        guard state == .recording || force else { return }
        if speechManager.isRecording && !force { return }
        
        if force {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        } else {
            if synthesizer.isSpeaking { return }
        }
        
        let localized = LocalizationManager.localizeOutput(text)
        let utterance = makeUtterance(localized, forceArabic: forceArabic)
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
                        .environment(\.layoutDirection, .leftToRight)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
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
                        Text(LocalizationManager.localizeOutput("Looking for: \(target)"))
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
                                .accessibilityLabel(LocalizationManager.localizeStatus(vm.speechManager.isRecording ? "Stop Listening" : "Voice Command"))
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
                                .accessibilityLabel(LocalizationManager.localizeStatus(vm.state == .recording ? "Stop Scanning" : "Start Scanning"))
                                
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
        .accessibilityAction(.magicTap) { vm.mainButtonTapped() }
        .edgesIgnoringSafeArea(.all)
        .animation(.default, value: vm.state)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Speech helpers
private extension CameraViewModel {
    func localizeObjectsIfNeeded(_ objects: [DetectedObject]) -> [DetectedObject] {
        guard LocalizationManager.isArabic else { return objects }
        return objects.map { obj in
            var copy = obj
            let localized = LocalizationManager.localizedName(for: obj.rawLabel.lowercased())
            copy.label = localized.capitalized
            return copy
        }
    }
    
    /// Builds a speech utterance with the right language and speed.
    func makeUtterance(_ text: String, forceArabic: Bool = false) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        let useArabic = forceArabic || LocalizationManager.isArabic
        if useArabic {
            utterance.voice = AVSpeechSynthesisVoice(language: "ar-SA")
            utterance.rate = 0.7
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.6
        }
        return utterance
    }
}

#Preview { FullCameraView() }
