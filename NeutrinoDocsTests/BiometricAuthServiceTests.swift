import XCTest
import LocalAuthentication
import NeutrinoAuth
@testable import NeutrinoDocs

/// Milestone 1 deliverable: **Use Face ID**.
///
/// `LAContext` cannot be driven from a test — there is no simulator API that produces a genuine
/// successful Face ID evaluation, and no way to synthesise a lockout — so the service is built
/// around the `BiometricEvaluating` seam and everything interesting is asserted through a fake that
/// returns canned `LAError`s.
///
/// The invariant these tests exist to protect: **no failure path unlocks.**
@MainActor
final class BiometricAuthServiceTests: XCTestCase {

    private var evaluator: FakeEvaluator!
    private var defaults: UserDefaults!
    private var sut: BiometricAuthService!

    override func setUp() {
        super.setUp()
        evaluator = FakeEvaluator()
        defaults = UserDefaults(suiteName: "BiometricTests-\(UUID().uuidString)")!
        sut = BiometricAuthService(defaults: defaults, evaluator: evaluator)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        sut = nil
        super.tearDown()
    }

    // MARK: - Availability

    func testFaceIDIsReportedAvailableWhenEnrolled() {
        evaluator.biometryType = .faceID
        evaluator.canEvaluateResult = .success(())

        XCTAssertEqual(sut.availability(), .available(.faceID))
        XCTAssertEqual(sut.biometryName, "Face ID")
        XCTAssertTrue(sut.availability().canEnable)
    }

    func testTouchIDIsReportedAvailableWhenEnrolled() {
        evaluator.biometryType = .touchID
        evaluator.canEvaluateResult = .success(())

        XCTAssertEqual(sut.availability(), .available(.touchID))
        XCTAssertEqual(sut.biometryName, "Touch ID")
    }

    func testUnenrolledBiometryIsDistinguishedFromUnavailableHardware() {
        evaluator.canEvaluateResult = .failure(LAError(.biometryNotEnrolled))
        XCTAssertEqual(sut.availability(), .notEnrolled)

        evaluator.canEvaluateResult = .failure(LAError(.biometryNotAvailable))
        XCTAssertEqual(sut.availability(), .notAvailable)

        evaluator.canEvaluateResult = .failure(LAError(.passcodeNotSet))
        XCTAssertEqual(sut.availability(), .passcodeNotSet)
    }

    // MARK: - Enabling

    func testEnablingIsRefusedWhenBiometryIsNotEnrolled() {
        evaluator.canEvaluateResult = .failure(LAError(.biometryNotEnrolled))

        sut.isEnabled = true

        XCTAssertFalse(sut.isEnabled, "The toggle must never lie about being on")
        XCTAssertEqual(sut.lastError, .notEnrolled)
    }

    /// A refused enable writes `false` back into the same property, re-entering `didSet`. Without
    /// the re-entrancy guard that pass would clear the very explanation the refusal recorded.
    func testARefusedEnableKeepsItsExplanation() {
        evaluator.canEvaluateResult = .failure(LAError(.passcodeNotSet))

        sut.isEnabled = true

        XCTAssertEqual(sut.lastError, .passcodeNotSet,
                       "The reason must survive the revert that follows it")
    }

    func testEnablingSucceedsWhenBiometryIsAvailableAndPersists() {
        evaluator.canEvaluateResult = .success(())

        sut.isEnabled = true

        XCTAssertTrue(sut.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: BiometricAuthService.Keys.enabled))
    }

    func testDisablingUnlocksAndClearsAnyError() {
        evaluator.canEvaluateResult = .success(())
        sut.isEnabled = true
        sut.lockOnLaunch()
        XCTAssertTrue(sut.isLocked)

        sut.isEnabled = false

        XCTAssertFalse(sut.isLocked)
        XCTAssertNil(sut.lastError)
    }

    // MARK: - Unlocking

    func testSuccessfulEvaluationUnlocks() async {
        enable()
        sut.lockOnLaunch()
        evaluator.evaluateResult = .success(())

        let unlocked = await sut.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertFalse(sut.isLocked)
        XCTAssertNil(sut.lastError)
    }

    func testCancellingDoesNotUnlock() async {
        enable()
        sut.lockOnLaunch()
        evaluator.evaluateResult = .failure(LAError(.userCancel))

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .cancelled)
    }

    func testFailedAuthenticationDoesNotUnlock() async {
        enable()
        sut.lockOnLaunch()
        evaluator.evaluateResult = .failure(LAError(.authenticationFailed))

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .failed)
    }

    func testBiometryLockoutDoesNotUnlock() async {
        enable()
        sut.lockOnLaunch()
        evaluator.evaluateResult = .failure(LAError(.biometryLockout))

        let unlocked = await sut.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(sut.isLocked)
        XCTAssertEqual(sut.lastError, .lockedOut)
    }

    /// Every mapped `LAError` must leave the app locked. This is the invariant stated as a sweep
    /// rather than as one case at a time, so a newly handled error code cannot quietly become an
    /// unlock path.
    func testNoEvaluationFailureEverUnlocks() async {
        let codes: [LAError.Code] = [
            .userCancel, .appCancel, .systemCancel, .authenticationFailed,
            .biometryLockout, .touchIDLockout, .biometryNotEnrolled, .touchIDNotEnrolled,
            .biometryNotAvailable, .touchIDNotAvailable, .passcodeNotSet, .invalidContext,
            .notInteractive,
        ]

        for code in codes {
            enable()
            sut.lockOnLaunch()
            evaluator.evaluateResult = .failure(LAError(code))

            let unlocked = await sut.unlock()

            XCTAssertFalse(unlocked, "LAError.\(code) must not unlock")
            XCTAssertTrue(sut.isLocked, "LAError.\(code) must leave the app locked")
        }
    }

    /// The passcode path exists precisely so a locked-out sensor cannot strand somebody outside
    /// their own encrypted documents.
    func testUserFallbackRetriesWithThePasscodeCapablePolicy() async {
        enable()
        sut.lockOnLaunch()
        evaluator.evaluateResults = [.failure(LAError(.userFallback)), .success(())]

        let unlocked = await sut.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 2)
        XCTAssertEqual(evaluator.lastPolicy, .deviceOwnerAuthentication,
                       "The passcode-capable policy is what makes the fallback work")
    }

    func testUnlockIsANoOpWhenTheFeatureIsOff() async {
        // Never enabled — the gate should simply not apply.
        let unlocked = await sut.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertFalse(sut.isLocked)
        XCTAssertEqual(evaluator.evaluateCallCount, 0)
    }

    // MARK: - Lock lifecycle

    func testColdLaunchLocksWhenEnabled() {
        enable()

        sut.lockOnLaunch()

        XCTAssertTrue(sut.isLocked)
    }

    func testColdLaunchDoesNotLockWhenDisabled() {
        sut.lockOnLaunch()

        XCTAssertFalse(sut.isLocked)
    }

    func testShouldLockIsFalseBeforeTheAppHasEverBackgrounded() {
        XCTAssertFalse(BiometricAuthService.shouldLock(lastBackgroundedAt: nil,
                                                       now: Date(),
                                                       gracePeriod: 60))
    }

    func testShouldLockOnlyOnceTheGracePeriodHasLapsed() {
        let backgrounded = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(BiometricAuthService.shouldLock(
            lastBackgroundedAt: backgrounded,
            now: backgrounded.addingTimeInterval(30),
            gracePeriod: 60))

        XCTAssertTrue(BiometricAuthService.shouldLock(
            lastBackgroundedAt: backgrounded,
            now: backgrounded.addingTimeInterval(60),
            gracePeriod: 60))
    }

    func testZeroGracePeriodLocksImmediately() {
        let backgrounded = Date()
        XCTAssertTrue(BiometricAuthService.shouldLock(lastBackgroundedAt: backgrounded,
                                                      now: backgrounded,
                                                      gracePeriod: 0))
    }

    func testReturningWithinTheGracePeriodDoesNotRelock() {
        enable()
        let now = Date(timeIntervalSince1970: 10_000)
        sut.now = { now }
        sut.gracePeriod = 60
        sut.sceneDidEnterBackground()
        sut.now = { now.addingTimeInterval(10) }

        sut.sceneDidBecomeActive()

        XCTAssertFalse(sut.isLocked)
    }

    func testReturningAfterTheGracePeriodRelocks() {
        enable()
        let now = Date(timeIntervalSince1970: 10_000)
        sut.now = { now }
        sut.gracePeriod = 60
        sut.sceneDidEnterBackground()
        sut.now = { now.addingTimeInterval(120) }

        sut.sceneDidBecomeActive()

        XCTAssertTrue(sut.isLocked)
    }

    /// The app-switcher snapshot is taken on `.inactive`, *before* `.background`. Obscuring only on
    /// background — or only when locked — would leak document titles into the switcher.
    /// Regression for the infinite Face ID loop: presenting the system prompt itself drops the
    /// scene to `.background` and back while `unlock()` is still in flight. That spurious
    /// backgrounding must not hand `sceneDidBecomeActive()` a fresh timestamp to re-lock against —
    /// otherwise a successful unlock is immediately undone and the lock screen re-prompts forever.
    func testBackgroundingWhileAlreadyLockedDoesNotArmARelockOnTheNextActive() {
        enable()
        sut.gracePeriod = 0
        sut.lockOnLaunch()
        XCTAssertTrue(sut.isLocked)

        // The Face ID sheet's own scene transitions, occurring while still locked/mid-auth.
        sut.sceneDidEnterBackground()
        sut.sceneDidBecomeActive()

        // Nothing to re-lock against: still simply locked, not re-armed into a loop.
        XCTAssertTrue(sut.isLocked)
    }

    /// Once genuinely unlocked, a real backgrounding still re-locks after the grace period — the
    /// fix must not disable re-locking altogether, only the spurious case above.
    func testGenuineBackgroundingAfterUnlockStillRelocks() async {
        enable()
        sut.gracePeriod = 0
        sut.lockOnLaunch()
        evaluator.evaluateResult = .success(())
        _ = await sut.unlock()
        XCTAssertFalse(sut.isLocked)

        sut.sceneDidEnterBackground()
        sut.sceneDidBecomeActive()

        XCTAssertTrue(sut.isLocked)
    }

    func testGoingInactiveObscuresImmediatelyEvenWithAGracePeriod() {
        enable()
        sut.gracePeriod = 900

        sut.sceneDidBecomeInactive()

        XCTAssertTrue(sut.isObscured)
        XCTAssertTrue(sut.shouldPresentOverlay)
        XCTAssertFalse(sut.isLocked, "Obscured is not the same as locked")
    }

    func testBecomingActiveClearsTheObscuring() {
        enable()
        sut.sceneDidBecomeInactive()

        sut.sceneDidBecomeActive()

        XCTAssertFalse(sut.isObscured)
    }

    func testNothingIsObscuredWhenTheLockIsOff() {
        sut.sceneDidBecomeInactive()

        XCTAssertFalse(sut.isObscured)
        XCTAssertFalse(sut.shouldPresentOverlay)
    }

    // MARK: - Key access

    func testKeyAccessIsAllowedWithoutAPromptWhenTheLockIsOff() async {
        let allowed = await sut.authenticateForKeyAccess()

        XCTAssertTrue(allowed)
        XCTAssertEqual(evaluator.evaluateCallCount, 0)
    }

    /// Re-prompting somebody who unlocked two seconds ago is friction with no security value.
    func testKeyAccessShortCircuitsInsideTheGracePeriod() async {
        enable()
        let now = Date(timeIntervalSince1970: 10_000)
        sut.now = { now }
        sut.gracePeriod = 60
        evaluator.evaluateResult = .success(())
        _ = await sut.unlock()
        let callsAfterUnlock = evaluator.evaluateCallCount
        sut.now = { now.addingTimeInterval(10) }

        let allowed = await sut.authenticateForKeyAccess()

        XCTAssertTrue(allowed)
        XCTAssertEqual(evaluator.evaluateCallCount, callsAfterUnlock, "No second prompt")
    }

    func testKeyAccessPromptsAgainOnceTheGracePeriodHasLapsed() async {
        enable()
        let now = Date(timeIntervalSince1970: 10_000)
        sut.now = { now }
        sut.gracePeriod = 60
        evaluator.evaluateResult = .success(())
        _ = await sut.unlock()
        let callsAfterUnlock = evaluator.evaluateCallCount
        sut.now = { now.addingTimeInterval(600) }

        _ = await sut.authenticateForKeyAccess()

        XCTAssertGreaterThan(evaluator.evaluateCallCount, callsAfterUnlock)
    }

    func testKeyAccessIsRefusedWhenAuthenticationFails() async {
        enable()
        evaluator.evaluateResult = .failure(LAError(.authenticationFailed))

        let allowed = await sut.authenticateForKeyAccess()

        XCTAssertFalse(allowed)
        XCTAssertEqual(sut.lastError, .failed)
    }

    // MARK: - Error copy

    /// A locked-out user genuinely can get in with their passcode; telling them to wait would
    /// strand them.
    func testLockoutCopyPointsAtThePasscodeRatherThanTellingUsersToWait() {
        let message = BiometricLockError.lockedOut.message
        XCTAssertTrue(message.lowercased().contains("passcode"))
        XCTAssertFalse(message.lowercased().contains("try again later"))
    }

    func testErrorMappingCoversTheCancelFamily() {
        XCTAssertEqual(BiometricLockError.from(LAError(.userCancel)), .cancelled)
        XCTAssertEqual(BiometricLockError.from(LAError(.appCancel)), .cancelled)
        XCTAssertEqual(BiometricLockError.from(LAError(.systemCancel)), .cancelled)
        XCTAssertEqual(BiometricLockError.from(LAError(.biometryLockout)), .lockedOut)
        XCTAssertEqual(BiometricLockError.from(LAError(.passcodeNotSet)), .passcodeNotSet)
        XCTAssertEqual(BiometricLockError.from(LAError(.invalidContext)), .failed)
    }

    // MARK: - Helpers

    private func enable() {
        evaluator.canEvaluateResult = .success(())
        evaluator.biometryType = .faceID
        sut.isEnabled = true
    }
}

// MARK: - FakeEvaluator

private final class FakeEvaluator: BiometricEvaluating {

    var biometryType: LABiometryType = .faceID
    var canEvaluateResult: Result<Void, LAError> = .success(())
    var evaluateResult: Result<Void, LAError> = .success(())
    /// Consumed in order when set, so a fallback retry can return something different.
    var evaluateResults: [Result<Void, LAError>] = []

    private(set) var evaluateCallCount = 0
    private(set) var lastPolicy: LAPolicy?

    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError> {
        canEvaluateResult
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError> {
        evaluateCallCount += 1
        lastPolicy = policy
        if !evaluateResults.isEmpty {
            return evaluateResults.removeFirst()
        }
        return evaluateResult
    }
}
