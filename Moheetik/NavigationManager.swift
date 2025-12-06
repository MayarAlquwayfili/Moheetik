//
//  NavigationManager.swift
//  Moheetik
//

import Foundation
import simd

final class NavigationManager {
    
    private var lastSpokenDirection: String = ""
    private var lastSpokenDistance: Float = 0
    private var lastDirectionTime: Date = .distantPast
    private var lastDistanceTime: Date = .distantPast
    private let naggingInterval: TimeInterval = 2.5
    private let distanceChangeThreshold: Float = 0.5
    private let leftThreshold: CGFloat = 0.35
    private let rightThreshold: CGFloat = 0.65
    private let centerEnterThreshold: CGFloat = 0.40
    private let centerExitThreshold: CGFloat = 0.60
    private let bearingAngleThreshold: Float = 10.0
    private let behindThreshold: Float = 135.0
    private var isInCenterZone: Bool = true
    
    func getGuidance(
        userPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        screenPoint: CGPoint?,
        screenSize: CGSize,
        cameraForward: SIMD3<Float>? = nil
    ) -> String? {
        let now = Date()
        let distance = simd_distance(userPosition, targetPosition)
        
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
        
        if let distanceMsg = getDistanceGuidance(distance: distance, now: now) {
            return distanceMsg
        }
        
        return nil
    }
    
    func reset() {
        lastSpokenDirection = ""
        lastSpokenDistance = 0
        lastDirectionTime = .distantPast
        lastDistanceTime = .distantPast
        isInCenterZone = true
    }
    
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
    
    private func speakDirection(_ direction: String, now: Date) -> String {
        lastSpokenDirection = direction
        lastDirectionTime = now
        return direction
    }
    
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
    
    var currentDistance: Float {
        return lastSpokenDistance
    }
    
    var currentDirection: String {
        return lastSpokenDirection
    }
}
