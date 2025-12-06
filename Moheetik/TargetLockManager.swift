//
//  TargetLockManager.swift
//  Moheetik

import Foundation
import CoreGraphics
 
final class TargetLockManager {
   
    private(set) var isLocked: Bool = false
    private(set) var isSearching: Bool = false
    private(set) var targetClassName: String?
    private(set) var targetDisplayName: String?
    private var lastBoundingBox: CGRect?
    private var lastCenter: CGPoint?
    private var predictedCenter: CGPoint?
    private var predictedBox: CGRect?
    private var velocity: CGPoint = .zero
    private var lastSize: CGFloat = 0
    private var lockedColorR: CGFloat = 0
    private var lockedColorG: CGFloat = 0
    private var lockedColorB: CGFloat = 0
    private var hasColorFingerprint: Bool = false
    private var framesLost: Int = 0
    private let maxLostFrames: Int = 5
    private let minScoreThreshold: CGFloat = 0.25
    private let maxCenterDistanceForMatch: CGFloat = 0.5
    private let maxSizeChangeRatio: CGFloat = 3.0
    private let velocityDecay: CGFloat = 0.7
    private let maxColorDifference: CGFloat = 0.15
    private let relockColorThreshold: CGFloat = 0.10
    private let maxSearchFrames: Int = 30
    
    func lockTarget(displayName: String, className: String, boundingBox: CGRect,
                    colorR: CGFloat = 0, colorG: CGFloat = 0, colorB: CGFloat = 0) {
        isLocked = true
        targetDisplayName = displayName
        targetClassName = className.lowercased()
        lastBoundingBox = boundingBox
        lastCenter = boundingBox.centerPoint
        predictedCenter = boundingBox.centerPoint
        predictedBox = boundingBox
        lastSize = boundingBox.calculatedArea
        velocity = .zero
        framesLost = 0
        lockedColorR = colorR
        lockedColorG = colorG
        lockedColorB = colorB
        hasColorFingerprint = (colorR + colorG + colorB) > 0
    }
    
    private func enterSearchingMode() {
        isLocked = false
        isSearching = true
        lastBoundingBox = nil
        lastCenter = nil
        predictedCenter = nil
        predictedBox = nil
        velocity = .zero
        lastSize = 0
    }
    
    func unlock() {
        isLocked = false
        isSearching = false
        targetClassName = nil
        targetDisplayName = nil
        lastBoundingBox = nil
        lastCenter = nil
        predictedCenter = nil
        predictedBox = nil
        velocity = .zero
        lastSize = 0
        framesLost = 0
        lockedColorR = 0
        lockedColorG = 0
        lockedColorB = 0
        hasColorFingerprint = false
    }
    
    func findLockedTarget(among candidates: [(box: CGRect, index: Int, r: CGFloat, g: CGFloat, b: CGFloat)]) -> Int? {
        if isSearching && !isLocked {
            return tryColorOnlyRelock(candidates: candidates)
        }
        
        guard isLocked, let lastBox = lastBoundingBox else { return nil }
        guard !candidates.isEmpty else {
            handleLostFrame()
            return nil
        }
        
        updatePrediction()
        
        let referenceBox = predictedBox ?? lastBox
        let colorValidCandidates: [(box: CGRect, index: Int, r: CGFloat, g: CGFloat, b: CGFloat)]
        if hasColorFingerprint {
            colorValidCandidates = candidates.filter { candidate in
                let colorDiff = colorDistance(r1: lockedColorR, g1: lockedColorG, b1: lockedColorB,
                                              r2: candidate.r, g2: candidate.g, b2: candidate.b)
                return colorDiff <= maxColorDifference
            }
        } else {
            colorValidCandidates = candidates
        }
        
        guard !colorValidCandidates.isEmpty else {
            handleLostFrame()
            return nil
        }
        
        var bestScore: CGFloat = -1
        var bestIndex: Int? = nil
        
        for candidate in colorValidCandidates {
            let score = calculateMatchScore(candidate: candidate.box, referenceBox: referenceBox)
            if score > bestScore {
                bestScore = score
                bestIndex = candidate.index
            }
        }
        
        if let idx = bestIndex, bestScore >= minScoreThreshold {
            let matchedBox = candidates.first { $0.index == idx }!.box
            updateTrackingState(newBox: matchedBox)
            framesLost = 0
            return idx
        }
        
        handleLostFrame()
        return nil
    }
    
    private func tryColorOnlyRelock(candidates: [(box: CGRect, index: Int, r: CGFloat, g: CGFloat, b: CGFloat)]) -> Int? {
        framesLost += 1
        if framesLost > maxSearchFrames {
            isSearching = false
            return nil
        }
        
        guard hasColorFingerprint, !candidates.isEmpty else { return nil }
        var bestColorMatch: (index: Int, box: CGRect, diff: CGFloat)? = nil
        
        for candidate in candidates {
            let colorDiff = colorDistance(r1: lockedColorR, g1: lockedColorG, b1: lockedColorB,
                                          r2: candidate.r, g2: candidate.g, b2: candidate.b)
            if colorDiff <= relockColorThreshold {
                if bestColorMatch == nil || colorDiff < bestColorMatch!.diff {
                    bestColorMatch = (candidate.index, candidate.box, colorDiff)
                }
            }
        }
        
        if let match = bestColorMatch {
            isLocked = true
            isSearching = false
            lastBoundingBox = match.box
            lastCenter = match.box.centerPoint
            predictedCenter = match.box.centerPoint
            predictedBox = match.box
            lastSize = match.box.calculatedArea
            velocity = .zero
            framesLost = 0
            return match.index
        }
        
        return nil
    }
    
    private func colorDistance(r1: CGFloat, g1: CGFloat, b1: CGFloat,
                               r2: CGFloat, g2: CGFloat, b2: CGFloat) -> CGFloat {
        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2
        return sqrt(dr*dr + dg*dg + db*db) / sqrt(3.0)
    }
    
    var isTargetLost: Bool {
        return !isLocked && !isSearching && framesLost > maxLostFrames
    }
    
    var isInSearchMode: Bool {
        return isSearching && !isLocked
    }
    
    var currentFramesLost: Int {
        return framesLost
    }
    
    
    private func calculateMatchScore(candidate: CGRect, referenceBox: CGRect) -> CGFloat {
        let iou = calculateIoU(rect1: candidate, rect2: referenceBox)
        let candidateCenter = candidate.centerPoint
        let referenceCenter = predictedCenter ?? referenceBox.centerPoint
        let distance = hypot(candidateCenter.x - referenceCenter.x, candidateCenter.y - referenceCenter.y)
        let centerScore = max(0, 1 - (distance / maxCenterDistanceForMatch))
        let candidateSize = candidate.calculatedArea
        let sizeRatio = lastSize > 0 ? max(candidateSize / lastSize, lastSize / candidateSize) : 1
        let sizeScore = sizeRatio <= maxSizeChangeRatio ? (1 / sizeRatio) : 0
        return iou * 0.6 + centerScore * 0.3 + sizeScore * 0.1
    }
    
    private func calculateIoU(rect1: CGRect, rect2: CGRect) -> CGFloat {
        let intersection = rect1.intersection(rect2)
        if intersection.isNull { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = rect1.calculatedArea + rect2.calculatedArea - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
    
    private func updateTrackingState(newBox: CGRect) {
        let newCenter = newBox.centerPoint
        
        if let oldCenter = lastCenter {
            let newVelocity = CGPoint(
                x: newCenter.x - oldCenter.x,
                y: newCenter.y - oldCenter.y
            )
            velocity = CGPoint(
                x: velocity.x * velocityDecay + newVelocity.x * (1 - velocityDecay),
                y: velocity.y * velocityDecay + newVelocity.y * (1 - velocityDecay)
            )
        }
        
        lastBoundingBox = newBox
        lastCenter = newCenter
        lastSize = newBox.calculatedArea
    }
    
    private func updatePrediction() {
        guard let center = lastCenter, let box = lastBoundingBox else { return }
        predictedCenter = CGPoint(
            x: center.x + velocity.x,
            y: center.y + velocity.y
        )
        predictedBox = box.offsetBy(dx: velocity.x, dy: velocity.y)
    }
    
    private func handleLostFrame() {
        framesLost += 1
        
        if framesLost > maxLostFrames && isLocked {
            enterSearchingMode()
            return
        }
        
        velocity = CGPoint(
            x: velocity.x * velocityDecay,
            y: velocity.y * velocityDecay
        )
        updatePrediction()
        if let predicted = predictedCenter {
            lastCenter = predicted
        }
        if let predBox = predictedBox {
            lastBoundingBox = predBox
        }
    }
}

/// Tracks persistent object IDs across frames to prevent ID jumping.
final class SessionIDTracker {
    
    /// Represents a tracked object instance with position history.
    private struct TrackedInstance {
        let id: Int
        var center: CGPoint
        var size: CGFloat
        var lastSeen: Date
        var framesMissed: Int
    }
    
    /// Counter for next available ID per class.
    private var classCounters: [String: Int] = [:]
    
    /// Known objects per class with position tracking.
    private var knownObjects: [String: [TrackedInstance]] = [:]
    
    /// Distance threshold for matching - INCREASED for stability.
    private let sameObjectThreshold: CGFloat = 0.35
    
    /// Maximum frames an object can be missing before being forgotten.
    private let maxMissedFrames: Int = 60
    
    /// Maximum time (seconds) to remember an object that left the frame.
    private let maxMemoryTime: TimeInterval = 10.0
    
    /// Assigns a persistent ID to an object, reusing existing ID if position matches.
    func assignID(forClass className: String, center: CGPoint, size: CGFloat) -> Int {
        let key = className.lowercased()
        let now = Date()
        
        // Try to match with existing known object FIRST (before cleanup)
        if let known = knownObjects[key], !known.isEmpty {
            var bestMatchIndex: Int? = nil
            var bestMatchDistance: CGFloat = .greatestFiniteMagnitude
            
            for (index, obj) in known.enumerated() {
                let distance = hypot(center.x - obj.center.x, center.y - obj.center.y)
                
                // FAST PATH: Accept first match within tight threshold
                if distance < 0.15 {
                    knownObjects[key]![index].center = center
                    knownObjects[key]![index].size = size
                    knownObjects[key]![index].lastSeen = now
                    knownObjects[key]![index].framesMissed = 0
                    return obj.id
                }
                
                // Track best match within wider threshold
                if distance < sameObjectThreshold && distance < bestMatchDistance {
                    let sizeRatio = size > 0 ? max(obj.size / size, size / obj.size) : 1.0
                    if sizeRatio < 4.0 {
                        bestMatchDistance = distance
                        bestMatchIndex = index
                    }
                }
            }
            
            // Found a match - update position and return existing ID
            if let matchIndex = bestMatchIndex {
                let existingID = known[matchIndex].id
                knownObjects[key]![matchIndex].center = center
                knownObjects[key]![matchIndex].size = size
                knownObjects[key]![matchIndex].lastSeen = now
                knownObjects[key]![matchIndex].framesMissed = 0
                return existingID
            }
        }
        
        // Cleanup stale objects AFTER matching (prevents premature deletion)
        cleanupStaleObjects(forClass: key, now: now)
        
        // No match found - create new ID
        let nextID = (classCounters[key] ?? 0) + 1
        classCounters[key] = nextID
        
        let newInstance = TrackedInstance(
            id: nextID,
            center: center,
            size: size,
            lastSeen: now,
            framesMissed: 0
        )
        
        if knownObjects[key] == nil {
            knownObjects[key] = []
        }
        knownObjects[key]!.append(newInstance)
        
        return nextID
    }
    
    /// Marks objects not seen in current frame (call once per frame after processing).
    func markFrameEnd(forClass className: String, visibleCenters: [CGPoint]) {
        let key = className.lowercased()
        guard var known = knownObjects[key] else { return }
        
        for index in known.indices {
            let isVisible = visibleCenters.contains { visibleCenter in
                let distance = hypot(visibleCenter.x - known[index].center.x,
                                    visibleCenter.y - known[index].center.y)
                return distance < sameObjectThreshold
            }
            
            if !isVisible {
                knownObjects[key]![index].framesMissed += 1
            }
        }
    }
    
    /// Removes objects that haven't been seen for too long.
    private func cleanupStaleObjects(forClass key: String, now: Date) {
        guard var known = knownObjects[key] else { return }
        
        knownObjects[key] = known.filter { obj in
            let timeSinceLastSeen = now.timeIntervalSince(obj.lastSeen)
            return timeSinceLastSeen < maxMemoryTime && obj.framesMissed < maxMissedFrames
        }
    }
    
    /// Resets all tracking state for a new session.
    func resetSession() {
        classCounters.removeAll()
        knownObjects.removeAll()
    }
    
    /// Returns the total count of unique IDs assigned for a class.
    func currentCount(forClass className: String) -> Int {
        return classCounters[className.lowercased()] ?? 0
    }
    
    /// Returns currently visible object count for a class.
    func visibleCount(forClass className: String) -> Int {
        let key = className.lowercased()
        guard let known = knownObjects[key] else { return 0 }
        return known.filter { $0.framesMissed == 0 }.count
    }
}


private extension CGRect {
    var centerPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
    var calculatedArea: CGFloat {
        width * height
    }
}

