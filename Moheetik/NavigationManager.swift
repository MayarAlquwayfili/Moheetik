//
//  NavigationManager.swift
//  Moheetik
//

import Foundation
import simd

/// Provides simple turn/distance guidance to the target.
final class NavigationManager {
    
    /// Last spoken turn message.
    private var lastSpokenDirection: String = ""
    /// Last spoken distance value.
    private var lastSpokenDistance: Float = 0
    /// Time last direction was spoken.
    private var lastDirectionTime: Date = .distantPast
    /// Time last distance was spoken.
    private var lastDistanceTime: Date = .distantPast
    /// Minimum pause between repeats.
    private let naggingInterval: TimeInterval = 1.5
    /// Distance change needed to speak again.
    private let distanceChangeThreshold: Float = 0.5
    /// Screen threshold to decide “left”.
    private let leftThreshold: CGFloat = 0.35
    /// Screen threshold to decide “right”.
    private let rightThreshold: CGFloat = 0.65
    /// Re-enter center zone threshold.
    private let centerEnterThreshold: CGFloat = 0.40
    /// Exit center zone threshold.
    private let centerExitThreshold: CGFloat = 0.60
    /// Angle considered “facing target”.
    private let bearingAngleThreshold: Float = 10.0
    /// Angle considered “behind you”.
    private let behindThreshold: Float = 135.0
    /// Tracks if user is roughly centered.
    private var isInCenterZone: Bool = true
    
    /// Builds guidance string (turn or distance) for the user.
    func getGuidance(
        userPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        screenPoint: CGPoint?,
        screenSize: CGSize,
        cameraForward: SIMD3<Float>? = nil
    ) -> String? {
        let now = Date()
        let distance = simd_distance(userPosition, targetPosition)
        
        let direction = getDirectionGuidance(
            screenPoint: screenPoint,
            screenSize: screenSize,
            userPosition: userPosition,
            targetPosition: targetPosition,
            cameraForward: cameraForward,
            now: now
        )
        let distanceMsg = getDistanceGuidance(distance: distance, now: now)
        
        // Priority 1: Critical Turns (Left/Right/Behind)
        if let dir = direction, (dir.contains("Turn") || dir.contains("behind")) {
            return LocalizationManager.localizeOutput(dir)
        }
        
        // Priority 2: Distance (Overrides "Move forward")
        if let dist = distanceMsg {
            return LocalizationManager.localizeOutput(dist)
        }
        
        // Priority 3: Move forward (Fallback)
        if let dir = direction {
            return LocalizationManager.localizeOutput(dir)
        }
        
        return nil
    }
    
    /// Clears stored timers and counts.
    func reset() {
        lastSpokenDirection = ""
        lastSpokenDistance = 0
        lastDirectionTime = .distantPast
        lastDistanceTime = .distantPast
        isInCenterZone = true
    }
    
    /// Picks a direction prompt from screen or blind guidance.
    private func getDirectionGuidance(
        screenPoint: CGPoint?,
        screenSize: CGSize,
        userPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        cameraForward: SIMD3<Float>?,
        now: Date
    ) -> String? {
        let timeSinceLastDirection = now.timeIntervalSince(lastDirectionTime)
        guard timeSinceLastDirection >= naggingInterval else {
            return nil
        }
        
        if let point = screenPoint, screenSize.width > 0 {
            return getScreenBasedDirection(normalizedX: point.x / screenSize.width, now: now)
        }
        
        return getBlindNavigationDirection(
            userPosition: userPosition,
            targetPosition: targetPosition,
            cameraForward: cameraForward,
            now: now
        )
    }
    
    /// Uses screen position to say left/right/forward.
    private func getScreenBasedDirection(normalizedX: CGFloat, now: Date) -> String? {
        if isInCenterZone {
            if normalizedX < leftThreshold {
                isInCenterZone = false
                return speakDirection("Turn left", now: now)
            } else if normalizedX > rightThreshold {
                isInCenterZone = false
                return speakDirection("Turn right", now: now)
            }
            return speakDirection("Move forward", now: now)
        } else {
            if normalizedX >= centerEnterThreshold && normalizedX <= centerExitThreshold {
                isInCenterZone = true
                return speakDirection("Move forward", now: now)
            }
            
            if normalizedX < leftThreshold {
                return speakDirection("Turn left", now: now)
            } else if normalizedX > rightThreshold {
                return speakDirection("Turn right", now: now)
            }
            return nil
        }
    }
    
    /// Uses angles only (no screen) to say left/right/forward.
    private func getBlindNavigationDirection(
        userPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        cameraForward: SIMD3<Float>?,
        now: Date
    ) -> String? {
        let toTarget = SIMD3<Float>(
            targetPosition.x - userPosition.x,
            0,
            targetPosition.z - userPosition.z
        )
        let toTargetNormalized = simd_normalize(toTarget)
        
        let forward: SIMD3<Float>
        if let camFwd = cameraForward {
            forward = simd_normalize(SIMD3<Float>(camFwd.x, 0, camFwd.z))
        } else {
            forward = SIMD3<Float>(0, 0, -1)
        }
        
        let dot = simd_dot(forward, toTargetNormalized)
        let cross = forward.x * toTargetNormalized.z - forward.z * toTargetNormalized.x
        let angleRadians = acos(simd_clamp(dot, -1.0, 1.0))
        let angleDegrees = angleRadians * 180.0 / .pi
        
        if angleDegrees > behindThreshold {
            isInCenterZone = false
            return speakDirection("Target is behind you. Turn around.", now: now)
        }
        
        if angleDegrees < bearingAngleThreshold {
            isInCenterZone = true
            return speakDirection("Move forward", now: now)
        }
        
        isInCenterZone = false
        if cross > 0 {
            return speakDirection("Turn right", now: now)
        } else {
            return speakDirection("Turn left", now: now)
        }
    }
    
    /// Records and returns the chosen direction phrase.
    private func speakDirection(_ direction: String, now: Date) -> String {
        lastSpokenDirection = direction
        lastDirectionTime = now
        return direction
    }
    
    /// Decides if distance should be spoken again.
    private func getDistanceGuidance(distance: Float, now: Date) -> String? {
        let timeSinceLastDistance = now.timeIntervalSince(lastDistanceTime)
        let distanceChange = abs(distance - lastSpokenDistance)
        
        let shouldAnnounce = (distanceChange >= distanceChangeThreshold) ||
                            (timeSinceLastDistance >= naggingInterval)
        
        guard shouldAnnounce else {
            return nil
        }
        
        lastSpokenDistance = distance
        lastDistanceTime = now
        
        return formatDistance(distance)
    }
    
    /// Formats distance into friendly speech text.
    private func formatDistance(_ meters: Float) -> String {
        if meters < 1.0 {
            return "Almost there"
        } else if meters < 10.0 {
            let rounded = (meters * 10).rounded() / 10
            if rounded == 1.0 {
                return "1 meter away"
            } else {
                let formatted = String(format: "%.1f", rounded)
                return "\(formatted) meters away"
            }
        } else {
            let rounded = Int(meters.rounded())
            return "\(rounded) meters away"
        }
    }
    
    var currentDistance: Float {
        return lastSpokenDistance
    }
    
    var currentDirection: String {
        return lastSpokenDirection
    }
}
