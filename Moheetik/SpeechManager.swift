//
//  SpeechManager.swift
//  Moheetik
//
//  Created by yumii on 02/12/2025.
//

import Speech
import SwiftUI
import Combine
import AVFoundation

/// Handles microphone speech input for voice commands.
class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    /// Recognizer configured to the app language (Arabic or English).
    private var speechRecognizer: SFSpeechRecognizer?
    /// Request that streams microphone buffers into speech.
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    /// Ongoing speech recognition task.
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Shared audio engine that captures the microphone audio.
    private let audioEngine = AVAudioEngine()
    /// Shared singleton to expose recording state.
    static let shared = SpeechManager()
    /// Serial queue to avoid main-thread blocking during audio teardown/start.
    private let audioQueue = DispatchQueue(label: "SpeechManager.audio.queue")
    /// Prevents overlapping start/stop toggles.
    private var isToggling = false
    
    /// True while the mic is listening.
    @Published var isRecording = false
    /// Latest recognized phrase from the mic.
    @Published var detectedText = ""
    
    /// Sets up the recognizer on creation.
    override init() {
        super.init()
        updateSpeechRecognizer()
    }
    
    /// Refreshes the recognizer to the current locale.
    private func updateSpeechRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: LocalizationManager.speechLocale)
        speechRecognizer?.delegate = self
    }
    
    /// Starts the microphone to listen for commands.
    func startRecording() {
        if isToggling { return }
        isToggling = true
        DispatchQueue.main.async { self.isRecording = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async { self.isToggling = false }
            }
            
            self.stopRecordingInternal()
            LocalizationManager.setLanguage()
            self.updateSpeechRecognizer()
            guard let recognizer = self.speechRecognizer else { return }
            
            // Keep session active; do not deactivate on stop.
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true, options: [.notifyOthersOnDeactivation])
            
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.recognitionRequest = request
            
            let inputNode = self.audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result = result {
                    DispatchQueue.main.async {
                        self?.detectedText = result.bestTranscription.formattedString
                    }
                }
                if error != nil || (result?.isFinal ?? false) { self?.stopRecording() }
            }
            
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }
            
            self.audioEngine.prepare()
            try? self.audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
                SpeechManager.shared.isRecording = true
            }
        }
    }
    
    /// Stops listening and tears down recognition safely.
    func stopRecording() {
        if isToggling { return }
        isToggling = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.stopRecordingInternal()
            DispatchQueue.main.async { self.isToggling = false }
        }
    }
    
    /// Internal teardown that cancels tasks and resets the engine.
    private func stopRecordingInternal() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        audioEngine.inputNode.removeTap(onBus: 0)
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        DispatchQueue.main.async {
            self.isRecording = false
            SpeechManager.shared.isRecording = false
            self.isToggling = false
        }
    }
}
