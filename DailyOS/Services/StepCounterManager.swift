import Foundation
import CoreMotion
import Combine

@MainActor
final class StepCounterManager: ObservableObject {
    @Published private(set) var currentSteps: Int = 0
    @Published private(set) var distanceMeters: Double = 0.0
    @Published private(set) var isHardwareAvailable: Bool = false
    @Published private(set) var isTracking: Bool = false
    @Published private(set) var statusMessage: String = "Ready to track steps"

    var onStepIncremented: ((Int) -> Void)?

    // Strictly lazy so CoreMotion is never instantiated at app launch or before UIWindowScene is active.
    private lazy var pedometer = CMPedometer()
    private lazy var motionManager = CMMotionManager()
    private var sessionStartDate: Date?
    private var lastStepPeakTimestamp: TimeInterval = 0

    init() {}

    static var authorizationStatusText: String {
        switch CMPedometer.authorizationStatus() {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }

    /// Prompts CoreMotion authorization lazily only when explicitly requested by user action.
    static func requestMotionPermission() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let tempPedometer = CMPedometer()
        let now = Date()
        tempPedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in }
    }

    func startTracking() {
        stopTracking()
        currentSteps = 0
        distanceMeters = 0.0
        let start = Date()
        sessionStartDate = start
        isTracking = true
        isHardwareAvailable = CMPedometer.isStepCountingAvailable()

        if isHardwareAvailable {
            statusMessage = "CoreMotion CMPedometer active — start walking!"
            pedometer.startUpdates(from: start) { [weak self] data, error in
                let errDesc = error?.localizedDescription
                let stepsValue = data?.numberOfSteps.intValue
                let distanceValue = data?.distance?.doubleValue

                Task { @MainActor [weak self] in
                    guard let self, self.isTracking else { return }
                    if let errDesc {
                        self.statusMessage = "Pedometer notice: \(errDesc). Using accelerometer step detector."
                        self.startAccelerometerFallbackIfNeeded()
                        return
                    }
                    if let stepsValue, stepsValue > self.currentSteps {
                        self.currentSteps = stepsValue
                        if let distanceValue {
                            self.distanceMeters = distanceValue
                        }
                        self.onStepIncremented?(stepsValue)
                    }
                }
            }
        } else {
            statusMessage = "CMPedometer unavailable — using CoreMotion accelerometer step detector."
            startAccelerometerFallbackIfNeeded()
        }
    }

    private func startAccelerometerFallbackIfNeeded() {
        guard motionManager.isAccelerometerAvailable, !motionManager.isAccelerometerActive else {
            return
        }
        motionManager.accelerometerUpdateInterval = 0.05
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] accelData, _ in
            guard let acceleration = accelData?.acceleration else { return }
            let magnitude = sqrt(
                acceleration.x * acceleration.x +
                acceleration.y * acceleration.y +
                acceleration.z * acceleration.z
            )
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                if magnitude > 1.32 && (now - self.lastStepPeakTimestamp) > 0.30 {
                    self.lastStepPeakTimestamp = now
                    self.currentSteps += 1
                    self.distanceMeters = Double(self.currentSteps) * 0.72
                    self.onStepIncremented?(self.currentSteps)
                }
            }
        }
    }

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        pedometer.stopUpdates()
        if motionManager.isAccelerometerActive {
            motionManager.stopAccelerometerUpdates()
        }
        sessionStartDate = nil
    }
}
