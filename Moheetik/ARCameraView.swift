//
//  ARCameraView.swift
//  Moheetik
//
//  Created by yumii on 01/12/2025.

import SwiftUI
import ARKit
import UIKit

/// Hosts the AR camera feed and links it to the view model.
struct ARCameraView: UIViewRepresentable {
    /// Camera view model that owns state and detections.
    @ObservedObject var vm: CameraViewModel
    
    /// Builds the AR view and starts the session.
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.providesAudioData = false
        arView.session.run(configuration)
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        context.coordinator.setupResetCallback()
        
        return arView
    }
    
    /// Keeps the coordinator synced with the live AR view.
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.arView = uiView
    }
    
    /// Creates the AR session coordinator.
    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }
    
    /// Handles AR session updates and ML processing.
    class Coordinator: NSObject, ARSessionDelegate {
        /// Shared camera view model.
        var vm: CameraViewModel
        /// Counts frames to throttle ML.
        var frameCounter = 0
        /// Forces the next ML pass.
        var forceNextInference = false
        /// Prevents piling up frames while ML is busy.
        private var isProcessingFrame = false
        /// Tracks target lock fingerprint.
        let targetLock = TargetLockManager()
        /// Persists IDs across frames.
        let sessionTracker = SessionIDTracker()
        /// Latest camera buffer for color sampling.
        var currentPixelBuffer: CVPixelBuffer?
        /// Live AR view for projections and hits.
        weak var arView: ARSCNView?
        /// Current locked anchor if any.
        var lockedAnchor: ARAnchor?
        /// Bounding box waiting for anchor placement.
        var pendingAnchorCreation: CGRect?
        /// Class name tied to pending anchor.
        var pendingClassName: String?
        /// Retry counter for anchor creation.
        var anchorCreationAttempts: Int = 0
        init(vm: CameraViewModel) { self.vm = vm }
        
        
        
        func setupResetCallback() {
            vm.onSessionReset = { [weak self] in
                self?.resetSession()
            }
        }
        
        func resetSession() {
            removeLockedAnchor()
            frameCounter = 0
            targetLock.unlock()
            sessionTracker.resetSession()
            currentPixelBuffer = nil
            pendingAnchorCreation = nil
            pendingClassName = nil
            anchorCreationAttempts = 0
            
            if let arView = arView {
                let configuration = ARWorldTrackingConfiguration()
                configuration.planeDetection = [.horizontal, .vertical]
                configuration.providesAudioData = false
                arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                print("🔄 ARSession fully reset")
            }
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            /// Stop all processing if the user is speaking to prevent lag
            if vm.speechManager.isRecording {
                return
            }
            guard vm.state == .recording else { return }
            guard UIApplication.shared.applicationState == .active else { return }
            guard !SpeechManager.shared.isRecording || vm.requestImmediateInference else { return }
            guard !isProcessingFrame else { return }
            
            frameCounter += 1
            if frameCounter % 2 != 0 { return }
            
            if let anchor = lockedAnchor {
                trackAnchor(anchor, frame: frame)
            }
            
            if let boundingBox = pendingAnchorCreation {
                tryCreateAnchor(for: boundingBox, frame: frame)
            }
            
            if forceNextInference {
                forceNextInference = false
            } else if vm.requestImmediateInference {
                vm.requestImmediateInference = false
            } else {
                guard frameCounter % 20 == 0 else { return }
            }
            
            isProcessingFrame = true
            autoreleasepool {
                let orientation = getExifOrientation()
                let pixelBuffer = frame.capturedImage
                currentPixelBuffer = pixelBuffer
                
                var requests: [VNCoreMLRequest] = []
                if let yolo = vm.yoloRequest { requests.append(yolo) }
                if let moheetik = vm.moheetikRequest { requests.append(moheetik) }
                
                guard !requests.isEmpty else { return }
                
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
                try? handler.perform(requests)
                
                var combinedResults: [VNRecognizedObjectObservation] = []
                if let yoloResults = vm.yoloRequest?.results as? [VNRecognizedObjectObservation] {
                    combinedResults.append(contentsOf: yoloResults)
                }
                if let moheetikResults = vm.moheetikRequest?.results as? [VNRecognizedObjectObservation] {
                    combinedResults.append(contentsOf: moheetikResults)
                }
                
                self.processResults(combinedResults, frame: frame)
                self.isProcessingFrame = false
            }
        }
        
        
        private func tryCreateAnchor(for boundingBox: CGRect, frame: ARFrame) {
            guard let arView = arView else { return }
            
            anchorCreationAttempts += 1
            
            if anchorCreationAttempts > 10 {
                print("⚠️ Anchor creation failed after 10 attempts")
                pendingAnchorCreation = nil
                pendingClassName = nil
                anchorCreationAttempts = 0
                return
            }
            
            let viewSize = arView.bounds.size
            let centerX = boundingBox.midX * viewSize.width
            let centerY = (1 - boundingBox.midY) * viewSize.height
            let screenPoint = CGPoint(x: centerX, y: centerY)
            let raycastQuery = arView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
            
            if let query = raycastQuery {
                let results = arView.session.raycast(query)
                if let firstResult = results.first {
                    let hitPosition = SCNVector3(
                        firstResult.worldTransform.columns.3.x,
                        firstResult.worldTransform.columns.3.y,
                        firstResult.worldTransform.columns.3.z
                    )
                    let projectedPoint = arView.projectPoint(hitPosition)
                    let projectedScreen = CGPoint(x: CGFloat(projectedPoint.x), y: CGFloat(projectedPoint.y))
                    let screenRect = CGRect(
                        x: boundingBox.minX * viewSize.width,
                        y: (1 - boundingBox.maxY) * viewSize.height,
                        width: boundingBox.width * viewSize.width,
                        height: boundingBox.height * viewSize.height
                    )
                    
                    let expandedRect = screenRect.insetBy(dx: -30, dy: -30)
                    
                    guard expandedRect.contains(projectedScreen) else {
                        print("⚠️ Raycast hit point outside bounding box, retrying...")
                        return
                    }
                    
                    let anchor = ARAnchor(name: "TargetAnchor", transform: firstResult.worldTransform)
                    arView.session.add(anchor: anchor)
                    lockedAnchor = anchor
                    pendingAnchorCreation = nil
                    pendingClassName = nil
                    anchorCreationAttempts = 0
                    
                    let boxSize = CGSize(width: boundingBox.width, height: boundingBox.height)
                    DispatchQueue.main.async {
                        self.vm.anchorCreated(id: anchor.identifier, boundingBoxSize: boxSize)
                    }
                    print("✅ 3D Anchor created (validated) at: \(firstResult.worldTransform.columns.3)")
                }
            }
        }
        
        
        private func trackAnchor(_ anchor: ARAnchor, frame: ARFrame) {
            guard let arView = arView else { return }
            
            let anchorPosition = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            
            let cameraPosition = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            
            let cameraTransform = frame.camera.transform
            let cameraForward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
            
            let distance = simd_distance(anchorPosition, cameraPosition)
            let anchorWorldPosition = SCNVector3(anchorPosition.x, anchorPosition.y, anchorPosition.z)
            let projectedPoint = arView.projectPoint(anchorWorldPosition)
            let screenBounds = arView.bounds
            let screenPoint = CGPoint(x: CGFloat(projectedPoint.x), y: CGFloat(projectedPoint.y))
            let isVisible = projectedPoint.z > 0 && projectedPoint.z < 1 &&
                            screenBounds.contains(screenPoint)
            
            DispatchQueue.main.async {
                self.vm.updateAnchorTracking(
                    distance: distance,
                    screenPosition: isVisible ? screenPoint : nil,
                    isVisible: isVisible,
                    screenSize: screenBounds.size,
                    userPosition: cameraPosition,
                    targetPosition: anchorPosition,
                    cameraForward: cameraForward
                )
                
                let closeRangeOverride = distance < 1.5
                let shouldShowOverlay = closeRangeOverride || self.vm.isVisuallyConfirmed
                
                if isVisible && shouldShowOverlay {
                    let label = self.vm.getLabelForAnchor(id: anchor.identifier)
                                ?? self.vm.lockedAnchorLabel
                                ?? self.vm.targetObject
                                ?? "Target"
                    
                    let normalizedX = screenPoint.x / screenBounds.width
                    let normalizedY = 1 - (screenPoint.y / screenBounds.height)
                    
                    var boxSize = self.vm.lastKnownBoundingBoxSize
                    if closeRangeOverride && boxSize.width < 0.1 {
                        boxSize = CGSize(width: 0.2, height: 0.25)
                    }
                    
                    let boundingBox = CGRect(
                        x: normalizedX - boxSize.width / 2,
                        y: normalizedY - boxSize.height / 2,
                        width: boxSize.width,
                        height: boxSize.height
                    )
                    
                    let anchorObject = DetectedObject(
                        label: label,
                        rawLabel: label.lowercased(),
                        confidence: 1.0,
                        boundingBox: boundingBox,
                        color: Color("MGreen")
                    )
                    self.vm.detectedObjects = [anchorObject]
                } else if isVisible && !shouldShowOverlay {
                    self.vm.detectedObjects = []
                } else if !isVisible {
                    self.vm.detectedObjects = []
                }
            }
        }
        
        
        func removeLockedAnchor() {
            if let anchor = lockedAnchor, let arView = arView {
                arView.session.remove(anchor: anchor)
            }
            lockedAnchor = nil
            pendingAnchorCreation = nil
        }
        
        func processResults(_ results: [VNRecognizedObjectObservation], frame: ARFrame) {
            let filtered = results.filter { $0.confidence > 0.4 }
            let yoloBoxes = filtered.map { $0.boundingBox }
            let yoloClasses = filtered.map { $0.labels.first?.identifier ?? "unknown" }
            
            /// If no objects detected, immediately clear stale data
            if filtered.isEmpty {
                DispatchQueue.main.async {
                    self.vm.updateYOLODetections(boxes: [], classNames: [])
                    if self.lockedAnchor == nil {
                        self.vm.updateDetections([])
                    }
                    self.vm.stopSpeakingImmediate()
                }
                return
            }
            
            let navigationClasses: Set<String> = [
                "door", "stairs", "elevator", "elevator_button", "exit", "entrance",
                "handrail", "ramp", "crossing", "sidewalk"
            ]
            
            var initialObjects = filtered.map { prediction -> DetectedObject in
                let rawLabel = prediction.labels.first?.identifier ?? "Unknown"
                let isNavigationObject = navigationClasses.contains(rawLabel.lowercased())
                
                var obj = DetectedObject(
                    label: "",
                    rawLabel: rawLabel,
                    confidence: prediction.confidence,
                    boundingBox: prediction.boundingBox,
                    color: isNavigationObject ? Color("MPurple") : Color("MBlue")
                )
                if let pixelBuffer = self.currentPixelBuffer {
                    let (r, g, b) = self.extractAverageColor(from: pixelBuffer, boundingBox: prediction.boundingBox)
                    obj.fingerprint = ColorFingerprint(r: r, g: g, b: b)
                }
                return obj
            }
            
            initialObjects.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            
            var labeledObjects: [DetectedObject] = []
            let grouped = Dictionary(grouping: initialObjects, by: { $0.rawLabel })
            
            for (key, objects) in grouped {
                var visibleCenters: [CGPoint] = []
                
                for var obj in objects {
                    let center = CGPoint(x: obj.boundingBox.midX, y: obj.boundingBox.midY)
                    let size = obj.boundingBox.width * obj.boundingBox.height
                    visibleCenters.append(center)
                    
                    let persistentID = self.sessionTracker.assignID(forClass: key, center: center, size: size)

                    if self.sessionTracker.currentCount(forClass: key) > 1 {
                        obj.label = "\(key.capitalized) \(persistentID)"
                    } else {
                        obj.label = key.capitalized
                    }
                    labeledObjects.append(obj)
                }
                
                self.sessionTracker.markFrameEnd(forClass: key, visibleCenters: visibleCenters)
            }
            
            let finalObjects = labeledObjects
            let finalBoxes = yoloBoxes
            let finalClasses = yoloClasses
            
            DispatchQueue.main.async {
                self.vm.updateYOLODetections(boxes: finalBoxes, classNames: finalClasses)
                
                /// Skip if anchor is active
                if self.lockedAnchor != nil {
                    return
                }
                
                if let targetName = self.vm.targetObject {
                    let baseName = targetName.components(separatedBy: " ").first?.lowercased() ?? ""
                    let candidates = finalObjects.filter { $0.rawLabel.lowercased().contains(baseName) }
                    
                    if self.lockedAnchor == nil && self.pendingAnchorCreation == nil {
                        let targetNumber = Int(targetName.components(separatedBy: " ").last ?? "1") ?? 1
                        let index = targetNumber - 1
                        let sortedCandidates = candidates.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        
                        if index < sortedCandidates.count {
                            let selected = sortedCandidates[index]
                            
                            self.pendingAnchorCreation = selected.boundingBox
                            self.pendingClassName = baseName
                            self.anchorCreationAttempts = 0
                            self.vm.lockedAnchorLabel = targetName
                            
                            self.targetLock.lockTarget(
                                displayName: targetName,
                                className: baseName,
                                boundingBox: selected.boundingBox,
                                colorR: selected.fingerprint.r,
                                colorG: selected.fingerprint.g,
                                colorB: selected.fingerprint.b
                            )
                            
                            var found = selected
                            found.label = targetName
                            found.color = Color("MGreen")
                            self.vm.updateDetections([found])
                        } else {
                            self.vm.updateDetections([])
                        }
                    } else if self.pendingAnchorCreation != nil {
                        let candidateBoxes = candidates.enumerated().map { elem in
                            (box: elem.element.boundingBox,
                             index: elem.offset,
                             r: elem.element.fingerprint.r,
                             g: elem.element.fingerprint.g,
                             b: elem.element.fingerprint.b)
                        }
                        
                        if let matchedIndex = self.targetLock.findLockedTarget(among: candidateBoxes) {
                            var found = candidates[matchedIndex]
                            found.label = targetName
                            found.color = Color("MGreen")
                            self.vm.updateDetections([found])
                            self.pendingAnchorCreation = found.boundingBox
                        } else {
                            self.vm.updateDetections([])
                        }
                    }
                } else {
                    self.removeLockedAnchor()
                    if self.targetLock.isLocked || self.targetLock.isInSearchMode {
                        self.targetLock.unlock()
                        self.sessionTracker.resetSession()
                    }
                    self.vm.updateDetections(finalObjects)
                }
            }
        }
   
        private func calculateIoU(rect1: CGRect, rect2: CGRect) -> CGFloat {
            let intersection = rect1.intersection(rect2)
            if intersection.isNull { return 0 }
            let area1 = rect1.width * rect1.height
            let area2 = rect2.width * rect2.height
            let union = area1 + area2 - (intersection.width * intersection.height)
            return union > 0 ? (intersection.width * intersection.height) / union : 0
        }
        
        private func distance(_ r1: CGRect, _ r2: CGRect) -> CGFloat {
            let p1 = CGPoint(x: r1.midX, y: r1.midY)
            let p2 = CGPoint(x: r2.midX, y: r2.midY)
            return hypot(p1.x - p2.x, p1.y - p2.y)
        }
        
        private func getExifOrientation() -> CGImagePropertyOrientation {
            let deviceOrientation = UIDevice.current.orientation
            switch deviceOrientation {
            case .portrait: return .right
            case .landscapeRight: return .down
            case .landscapeLeft: return .up
            case .portraitUpsideDown: return .left
            default: return .right
            }
        }
        
        func extractAverageColor(from pixelBuffer: CVPixelBuffer, boundingBox: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return (0, 0, 0)
            }
            
            let x = Int(boundingBox.minX * CGFloat(width))
            let y = Int((1 - boundingBox.maxY) * CGFloat(height))
            let boxWidth = Int(boundingBox.width * CGFloat(width))
            let boxHeight = Int(boundingBox.height * CGFloat(height))
            let sampleX = max(0, min(width - 1, x + boxWidth / 4))
            let sampleY = max(0, min(height - 1, y + boxHeight / 4))
            let sampleW = max(1, boxWidth / 2)
            let sampleH = max(1, boxHeight / 2)
            
            var totalR: CGFloat = 0
            var totalG: CGFloat = 0
            var totalB: CGFloat = 0
            var sampleCount: CGFloat = 0
                    
            let step = 4
            for py in stride(from: sampleY, to: min(sampleY + sampleH, height), by: step) {
                for px in stride(from: sampleX, to: min(sampleX + sampleW, width), by: step) {
                    let offset = py * bytesPerRow + px * 4
                    let ptr = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                    totalB += CGFloat(ptr[0]) / 255.0
                    totalG += CGFloat(ptr[1]) / 255.0
                    totalR += CGFloat(ptr[2]) / 255.0
                    sampleCount += 1
                }
            }
            
            guard sampleCount > 0 else { return (0, 0, 0) }
            return (totalR / sampleCount, totalG / sampleCount, totalB / sampleCount)
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { width * height }
}
