//
//  SpeechManager.swift
//  Moheetik
//
//  Created by yumii on 02/12/2025.
//

import Speech
import SwiftUI
import Combine

class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    @Published var isRecording = false
    @Published var detectedText = ""
    
    override init() { super.init(); speechRecognizer?.delegate = self }
    
    func startRecording() {
        stopRecording()
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let result = result { DispatchQueue.main.async { self?.detectedText = result.bestTranscription.formattedString } }
            if error != nil || (result?.isFinal ?? false) { self?.stopRecording() }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in recognitionRequest.append(buffer) }
        
        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true
    }
    
    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            isRecording = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
