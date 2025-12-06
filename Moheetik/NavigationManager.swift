//
//  NavigationManager.swift
//  Moheetik
//
//  Provides continuous voice guidance for blind navigation.
//

import Foundation
import simd

/// Manages navigation guidance with "Nagging Mode" for persistent feedback.
final class NavigationManager {
    
    /// Last spoken direction instruction.
    private var lastSpokenDirection: String = ""
    
    /// Last announced distance value in meters.
    private var lastSpokenDistance: Float = 0
    
    /// Timestamp of the last direction announcement.
    private var lastDirectionTime: Date = .distantPast
    
    /// Timestamp of the last distance announcement.
    private var lastDistanceTime: Date = .distantPast
    
    /// Nagging interval: repeat instructions every 2.5 seconds if user hasn't corrected.
    private let naggingInterval: TimeInterval = 2.5
    
    /// Minimum distance change (meters) to trigger a new announcement.
    private let distanceChangeThreshold: Float = 0.5
    
    /// Screen X threshold for "Turn left" trigger (normalized 0-1).
    private let leftThreshold: CGFloat = 0.35
    
    /// Screen X threshold for "Turn right" trigger (normalized 0-1).
    private let rightThreshold: CGFloat = 0.65
    
    /// Screen X threshold to enter center zone (normalized 0-1).
    private let centerEnterThreshold: CGFloat = 0.40
    
    /// Screen X threshold to exit center zone (normalized 0-1).
    private let centerExitThreshold: CGFloat = 0.60
    
    /// Bearing angle threshold (degrees) for minor corrections.
    private let bearingAngleThreshold: Float = 10.0
    
    /// Bearing angle threshold (degrees) for "behind you" warning.
    private let behindThreshold: Float = 135.0
    
    /// Tracks whether the target is currently in the center zone.
    private var isInCenterZone: Bool = true
    
    /// Returns navigation guidance based on user position, target position, and screen location.
    func getGuidance(
        userPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        screenPoint: CGPoint?,
        screenSize: CGSize,
        cameraForward: SIMD3<Float>? = nil
    ) -> String? {
        let now = Date()
        let distance = simd_distance(userPosition, targetPosition)
        
        // Priority 1: Direction guidance (includes "Behind You" safety check)
        if let direction = getDirectionGuidance(
            screenPoint: screenPoint,
            screenSize: screenSize,
            userPosition: userPosition,
            targetPosition: targetPosition,
            cameraForward: cameraForward,
            now: now
        ) {
            return direction
        }
        
        // Priority 2: Distance guidance (when facing correct direction)
        if let distanceMsg = getDistanceGuidance(distance: distance, now: now) {
            return distanceMsg
        }
        
        return nil
    }
    
    /// Resets all navigation state for a fresh session.
    func reset() {
        lastSpokenDirection = ""
        lastSpokenDistance = 0
        lastDirectionTime = .distantPast
        lastDistanceTime = .distantPast
        isInCenterZone = true
    }
    
    /// Determines direction guidance using screen position or blind navigation.
    private func getDirectionGuidance(
        screenPoint: CGPoint?,
        screenSize: CGSize,
        userPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        cameraForward: SIMD3<Float>?,
        now: Date
    ) -> String? {
        // NAGGING MODE: Check if enough time passed to repeat instruction
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
    
    /// Returns direction guidance based on target's screen X position.
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
    
    /// Returns direction guidance using 3D bearing angle when target is off-screen.
    /// Includes "Behind You" safety protocol for angles > 135°.
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
        
        // SAFETY PROTOCOL: Target is behind user (> 135°)
        if angleDegrees > behindThreshold {
            isInCenterZone = false
            return speakDirection("Target is behind you. Turn around.", now: now)
        }
        
        // Target is roughly ahead - move forward
        if angleDegrees < bearingAngleThreshold {
            isInCenterZone = true
            return speakDirection("Move forward", now: now)
        }
        
        // Target is to the side - guide turn direction
        isInCenterZone = false
        if cross > 0 {
            return speakDirection("Turn right", now: now)
        } else {
            return speakDirection("Turn left", now: now)
        }
    }
    
    /// Speaks a direction and updates timestamp. NAGGING MODE: Always speaks if cooldown passed.
    private func speakDirection(_ direction: String, now: Date) -> String {
        lastSpokenDirection = direction
        lastDirectionTime = now
        return direction
    }
    
    /// Returns distance guidance if enough time passed or distance changed significantly.
    private func getDistanceGuidance(distance: Float, now: Date) -> String? {
        let timeSinceLastDistance = now.timeIntervalSince(lastDistanceTime)
        let distanceChange = abs(distance - lastSpokenDistance)
        
        // NAGGING MODE: Announce if significant change OR nagging interval passed
        let shouldAnnounce = (distanceChange >= distanceChangeThreshold) ||
                            (timeSinceLastDistance >= naggingInterval)
        
        guard shouldAnnounce else {
            return nil
        }
        
        lastSpokenDistance = distance
        lastDistanceTime = now
        
        return formatDistance(distance)
    }
    
    /// Formats distance in meters for speech output.
    private func formatDistance(_ meters: Float) -> String {
        if meters < 1.0 {
            return "Almost there"
        } else if meters < 10.0 {
            let rounded = (meters * 10).rounded() / 10
            if rounded == 1.0 {
                return "1 meter away"
            } else {
                return String(format: "%.1f meters away", rounded)
            }
        } else {
            let rounded = Int(meters.rounded())
            return "\(rounded) meters away"
        }
    }
    
    /// Returns the last spoken distance value.
    var currentDistance: Float {
        return lastSpokenDistance
    }
    
    /// Returns the last spoken direction instruction.
    var currentDirection: String {
        return lastSpokenDirection
    }
}
