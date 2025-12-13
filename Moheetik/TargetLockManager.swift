//
//  TargetLockManager.swift
//  Moheetik

import Foundation
import CoreGraphics
 
/// Tracks and maintains a locked target across frames.
final class TargetLockManager {
   
    /// True when a target is locked.
    private(set) var isLocked: Bool = false
    /// True when trying to relock after loss.
    private(set) var isSearching: Bool = false
    /// Class name of the locked target.
    private(set) var targetClassName: String?
    /// Display name of the locked target.
    private(set) var targetDisplayName: String?
    /// Last seen box of the target.
    private var lastBoundingBox: CGRect?
    /// Last center point of the target.
    private var lastCenter: CGPoint?
    /// Predicted next center for smoothing.
    private var predictedCenter: CGPoint?
    /// Predicted next box for smoothing.
    private var predictedBox: CGRect?
    /// Smoothed motion vector.
    private var velocity: CGPoint = .zero
    /// Last size (area) of the box.
    private var lastSize: CGFloat = 0
    /// Stored color for relock (R).
    private var lockedColorR: CGFloat = 0
    /// Stored color for relock (G).
    private var lockedColorG: CGFloat = 0
    /// Stored color for relock (B).
    private var lockedColorB: CGFloat = 0
    /// True when color is available for relock.
    private var hasColorFingerprint: Bool = false
    /// Frames since target was last seen.
    private var framesLost: Int = 0
    /// Max frames tolerated before giving up.
    private let maxLostFrames: Int = 5
    /// Minimum score to accept a match.
    private let minScoreThreshold: CGFloat = 0.25
    /// Allowed center shift for a match.
    private let maxCenterDistanceForMatch: CGFloat = 0.5
    /// Allowed size change ratio for match.
    private let maxSizeChangeRatio: CGFloat = 3.0
    /// Dampens velocity over time.
    private let velocityDecay: CGFloat = 0.7
    /// Max allowed color difference for relock.
    private let maxColorDifference: CGFloat = 0.15
    /// Stricter color threshold for relock.
    private let relockColorThreshold: CGFloat = 0.10
    /// How many frames to try color-only relock.
    private let maxSearchFrames: Int = 30
    
    /// Saves target info and marks it as locked.
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
    
    /// Clears all lock info and returns to idle.
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
    
    /// Attempts to match the locked target in new detections.
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
        let colorValidCandidates: [(box: CGRect, index: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = {
            if hasColorFingerprint {
                return candidates.filter { candidate in
                    let colorDiff = colorDistance(r1: lockedColorR, g1: lockedColorG, b1: lockedColorB,
                                                  r2: candidate.r, g2: candidate.g, b2: candidate.b)
                    return colorDiff <= maxColorDifference
                }
            } else {
                return candidates
            }
        }()
        
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
    
    /// Uses only color to relock when tracking is lost.
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
    
    /// Computes simple color distance between two samples.
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
    
    
    /// Scores how well a candidate box matches the last target.
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
    
    /// Computes overlap score between two boxes.
    private func calculateIoU(rect1: CGRect, rect2: CGRect) -> CGFloat {
        let intersection = rect1.intersection(rect2)
        if intersection.isNull { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = rect1.calculatedArea + rect2.calculatedArea - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
    
    /// Updates stored target state after a successful match.
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
    
    /// Predicts next box position based on velocity.
    private func updatePrediction() {
        guard let center = lastCenter, let box = lastBoundingBox else { return }
        predictedCenter = CGPoint(
            x: center.x + velocity.x,
            y: center.y + velocity.y
        )
        predictedBox = box.offsetBy(dx: velocity.x, dy: velocity.y)
    }
    
    /// Handles bookkeeping when the target is not found in a frame.
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

final class SessionIDTracker {
    
    private struct TrackedInstance {
        let id: Int
        var center: CGPoint
        var size: CGFloat
        var lastSeen: Date
        var framesMissed: Int
    }
    
    private var classCounters: [String: Int] = [:]
    private var knownObjects: [String: [TrackedInstance]] = [:]
    private let sameObjectThreshold: CGFloat = 0.35
    private let maxMissedFrames: Int = 60
    private let maxMemoryTime: TimeInterval = 10.0

    func assignID(forClass className: String, center: CGPoint, size: CGFloat) -> Int {
        let key = className.lowercased()
        let now = Date()
        
        ///Try to match with known instances
        if let known = knownObjects[key], !known.isEmpty {
            var bestMatchIndex: Int? = nil
            var bestMatchDistance: CGFloat = .greatestFiniteMagnitude
            
            /// Loop over existing objects to find close matches
            for (index, obj) in known.enumerated() {
                let distance = hypot(center.x - obj.center.x, center.y - obj.center.y)
                
                /// If very close, update and return same ID
                if distance < 0.15 {
                    knownObjects[key]![index].center = center
                    knownObjects[key]![index].size = size
                    knownObjects[key]![index].lastSeen = now
                    knownObjects[key]![index].framesMissed = 0
                    return obj.id
                }
                
                /// Track best match if within threshold and similar size
                if distance < sameObjectThreshold && distance < bestMatchDistance {
                    let sizeRatio = size > 0 ? max(obj.size / size, size / obj.size) : 1.0
                    if sizeRatio < 4.0 {
                        bestMatchDistance = distance
                        bestMatchIndex = index
                    }
                }
            }
            
            /// If best match found, update and return that ID
            if let matchIndex = bestMatchIndex {
                let existingID = known[matchIndex].id
                knownObjects[key]![matchIndex].center = center
                knownObjects[key]![matchIndex].size = size
                knownObjects[key]![matchIndex].lastSeen = now
                knownObjects[key]![matchIndex].framesMissed = 0
                return existingID
            }
        }
        
        /// Clean out stale objects before adding new
        cleanupStaleObjects(forClass: key, now: now)
        
        /// Generate next ID counter for this class
        let nextID = (classCounters[key] ?? 0) + 1
        classCounters[key] = nextID
        
        /// Create and store new tracked instance
        let newInstance = TrackedInstance(
            id: nextID,
            center: center,
            size: size,
            lastSeen: now,
            framesMissed: 0
        )
        
        /// Append new instance to storage
        if knownObjects[key] == nil {
            knownObjects[key] = []
        }
        knownObjects[key]!.append(newInstance)
        
        return nextID
    }
    
    func markFrameEnd(forClass className: String, visibleCenters: [CGPoint]) {
        /// Normalize key and fetch known objects
        let key = className.lowercased()
        guard var known = knownObjects[key] else { return }
        
        /// Check visibility for each known object
        for index in known.indices {
            let isVisible = visibleCenters.contains { visibleCenter in
                let distance = hypot(visibleCenter.x - known[index].center.x,
                                    visibleCenter.y - known[index].center.y)
                return distance < sameObjectThreshold
            }
            
            /// Increment missed frames if not visible
            if !isVisible {
                knownObjects[key]![index].framesMissed += 1
            }
        }
    }
    
    private func cleanupStaleObjects(forClass key: String, now: Date) {
        /// Guard if nothing tracked for this key
        guard var known = knownObjects[key] else { return }
        
        /// Filter out items too old or too many misses
        knownObjects[key] = known.filter { obj in
            let timeSinceLastSeen = now.timeIntervalSince(obj.lastSeen)
            return timeSinceLastSeen < maxMemoryTime && obj.framesMissed < maxMissedFrames
        }
    }
    
    func resetSession() {
        /// Clear all counters and known objects
        classCounters.removeAll()
        knownObjects.removeAll()
    }
    
    func currentCount(forClass className: String) -> Int {
        /// Return current ID count for class
        return classCounters[className.lowercased()] ?? 0
    }
    
    func visibleCount(forClass className: String) -> Int {
        /// Count objects with zero missed frames
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

