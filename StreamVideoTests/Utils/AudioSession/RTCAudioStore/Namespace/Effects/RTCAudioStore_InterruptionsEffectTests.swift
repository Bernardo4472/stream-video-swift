//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

@testable import StreamVideo
import StreamWebRTC
import XCTest

final class RTCAudioStore_InterruptionsEffectTests: XCTestCase, @unchecked Sendable {

    private enum TestError: Error { case stub }

    private var session: RTCAudioSession!
    private var publisher: RTCAudioSessionPublisher!
    private var appState: MockAppStateAdapter!
    private var subject: RTCAudioStore.InterruptionsEffect!
    private var dispatched: [[StoreActionBox<RTCAudioStore.Namespace.Action>]]!

    override func setUp() {
        super.setUp()
        session = RTCAudioSession.sharedInstance()
        publisher = .init(session)
        appState = .init()
        appState.makeShared()
        subject = .init(publisher)
        dispatched = []
    }

    override func tearDown() {
        appState.dismante()
        subject.dispatcher = nil
        subject.stateProvider = nil
        subject = nil
        publisher = nil
        appState = nil
        session = nil
        dispatched = nil
        super.tearDown()
    }

    func test_didBeginInterruption_dispatchesSetInterruptedTrue() {
        let dispatcherExpectation = expectation(description: "Dispatcher called")
        dispatcherExpectation.assertForOverFulfill = false

        subject.dispatcher = .init { [weak self] actions, _, _, _ in
            self?.dispatched.append(actions)
            dispatcherExpectation.fulfill()
        }

        publisher.audioSessionDidBeginInterruption(session)

        wait(for: [dispatcherExpectation], timeout: 1)

        guard let actions = dispatched.first else {
            return XCTFail("Expected dispatched actions.")
        }

        XCTAssertEqual(actions.count, 1)
        guard case .setInterrupted(true) = actions[0].wrappedValue else {
            return XCTFail("Expected setInterrupted(true).")
        }
    }

    func test_didEndInterruption_isInterrupted_shouldResumeFalse_dispatchesSetInterruptedFalseOnly() {
        let dispatcherExpectation = expectation(description: "Dispatcher called")
        dispatcherExpectation.assertForOverFulfill = false

        subject.dispatcher = .init { [weak self] actions, _, _, _ in
            self?.dispatched.append(actions)
            dispatcherExpectation.fulfill()
        }

        subject.stateProvider = { [weak self] in
            self?.makeState(isInterrupted: true)
        }

        publisher.audioSessionDidEndInterruption(session, shouldResumeSession: false)

        wait(for: [dispatcherExpectation], timeout: 1)

        guard let actions = dispatched.first else {
            return XCTFail("Expected dispatched actions.")
        }

        XCTAssertEqual(actions.count, 1)
        guard case .setInterrupted(false) = actions[0].wrappedValue else {
            return XCTFail("Expected setInterrupted(false).")
        }
    }

    func test_didEndInterruption_isInterrupted_shouldResumeTrue_withoutAudioDeviceModule_dispatchesSetInterruptedFalse() {
        let dispatcherExpectation = expectation(description: "Dispatcher called")
        dispatcherExpectation.assertForOverFulfill = false

        subject.dispatcher = .init { [weak self] actions, _, _, _ in
            self?.dispatched.append(actions)
            dispatcherExpectation.fulfill()
        }

        subject.stateProvider = { [weak self] in
            self?.makeState(
                isInterrupted: true,
                audioDeviceModule: nil
            )
        }

        publisher.audioSessionDidEndInterruption(session, shouldResumeSession: true)

        wait(for: [dispatcherExpectation], timeout: 1)

        guard let actions = dispatched.first else {
            return XCTFail("Expected dispatched actions.")
        }

        XCTAssertEqual(actions.count, 1)
        guard case .setInterrupted(false) = actions[0].wrappedValue else {
            return XCTFail("Expected setInterrupted(false).")
        }
    }

    func test_didEndInterruption_isInterrupted_shouldResumeTrue_withAudioDeviceModule_dispatchesRecoveryActions() {
        let dispatcherExpectation = expectation(description: "Dispatcher called")
        dispatcherExpectation.assertForOverFulfill = false

        subject.dispatcher = .init { [weak self] actions, _, _, _ in
            self?.dispatched.append(actions)
            dispatcherExpectation.fulfill()
        }

        let module = AudioDeviceModule(MockRTCAudioDeviceModule())
        subject.stateProvider = { [weak self] in
            self?.makeState(
                isInterrupted: true,
                isRecording: true,
                isMicrophoneMuted: true,
                audioDeviceModule: module
            )
        }

        publisher.audioSessionDidEndInterruption(session, shouldResumeSession: true)

        wait(for: [dispatcherExpectation], timeout: 1)

        guard let actions = dispatched.first else {
            return XCTFail("Expected dispatched actions.")
        }

        XCTAssertEqual(actions.count, 4)
        guard case .setInterrupted(false) = actions[0].wrappedValue else {
            return XCTFail("Expected action[0] setInterrupted(false).")
        }
        guard case .setRecording(false) = actions[1].wrappedValue else {
            return XCTFail("Expected action[1] setRecording(false).")
        }
        guard case .setRecording(true) = actions[2].wrappedValue else {
            return XCTFail("Expected action[2] setRecording(true).")
        }
        guard case .setMicrophoneMuted(true) = actions[3].wrappedValue else {
            return XCTFail("Expected action[3] setMicrophoneMuted(true).")
        }
    }

    // MARK: - Foreground recovery

    func test_didEndInterruptionWhileBackgrounded_foregroundWhileRecording_replaysRecordingRestart() {
        appState.stubbedState = .background
        let interruptionEndExpectation = expectation(description: "Interruption end processed")
        let replayExpectation = expectation(description: "Replay dispatched")
        let captured = Atomic<[RTCAudioStore.StoreAction]>(wrappedValue: [])
        subject.dispatcher = .init { actions, _, _, _ in
            let unwrapped = actions.map(\.wrappedValue)
            if case .setInterrupted(false) = unwrapped.first {
                interruptionEndExpectation.fulfill()
            }
            // The foreground replay is the 3-action recording restart batch,
            // distinct from the 4-action interruption-end recovery batch.
            guard
                unwrapped.count == 3,
                case .setRecording(false) = unwrapped[0]
            else {
                return
            }
            captured.mutate { _ in unwrapped }
            replayExpectation.fulfill()
        }
        subject.stateProvider = { [weak self] in
            self?.makeState(
                isActive: true,
                isInterrupted: true,
                isRecording: true,
                isMicrophoneMuted: true,
                audioDeviceModule: AudioDeviceModule(MockRTCAudioDeviceModule())
            )
        }

        // Wait for the interruption-end handling (which flags the pending
        // recovery while backgrounded) before transitioning to foreground.
        publisher.audioSessionDidEndInterruption(session, shouldResumeSession: true)
        wait(for: [interruptionEndExpectation], timeout: defaultTimeout)

        appState.stubbedState = .foreground
        wait(for: [replayExpectation], timeout: defaultTimeout)

        let replay = captured.wrappedValue
        guard
            replay.count == 3,
            case .setRecording(false) = replay[0],
            case .setRecording(true) = replay[1],
            case .setMicrophoneMuted(true) = replay[2]
        else {
            return XCTFail("Unexpected replay actions: \(replay).")
        }
    }

    func test_didEndInterruptionWhileForeground_foregroundTransition_doesNotReplay() async {
        appState.stubbedState = .foreground
        subject.dispatcher = .init { [weak self] actions, _, _, _ in
            self?.dispatched.append(actions)
        }
        subject.stateProvider = { [weak self] in
            self?.makeState(isActive: true, isInterrupted: true, isRecording: true)
        }

        publisher.audioSessionDidEndInterruption(session, shouldResumeSession: true)
        appState.stubbedState = .background
        appState.stubbedState = .foreground

        await wait(for: 0.5)
        XCTAssertEqual(dispatched.count, 1)
    }

    func test_foregroundTransitionWithoutInterruption_doesNotReplay() async {
        appState.stubbedState = .background
        subject.dispatcher = .init { [weak self] actions, _, _, _ in
            self?.dispatched.append(actions)
        }
        subject.stateProvider = { [weak self] in
            self?.makeState(isActive: true, isRecording: true)
        }

        appState.stubbedState = .foreground

        await wait(for: 0.5)
        XCTAssertTrue(dispatched.isEmpty)
    }

    // MARK: - Crash / stress

    func test_concurrentInterruptionAndForegroundStorm_doesNotCrashAndStaysResponsive() {
        let iterations = 500
        let module = AudioDeviceModule(MockRTCAudioDeviceModule())
        subject.stateProvider = { [weak self] in
            self?.makeState(
                isActive: true,
                isInterrupted: true,
                isRecording: true,
                isMicrophoneMuted: false,
                audioDeviceModule: module
            )
        }
        let sawRecovery = expectation(description: "Recovery dispatched")
        sawRecovery.assertForOverFulfill = false
        subject.dispatcher = .init { actions, _, _, _ in
            let unwrapped = actions.map(\.wrappedValue)
            if unwrapped.count == 3, case .setRecording(false) = unwrapped[0] {
                sawRecovery.fulfill()
            }
        }

        let group = DispatchGroup()
        let interruptionsQueue = DispatchQueue(label: "test.interruptions")
        let appStateQueue = DispatchQueue(label: "test.appstate")

        // Two independent producers (mirroring the real notification thread and
        // the main thread) hammer the single serial processing queue.
        group.enter()
        interruptionsQueue.async { [session, publisher] in
            for _ in 0..<iterations {
                publisher?.audioSessionDidBeginInterruption(session!)
                publisher?.audioSessionDidEndInterruption(session!, shouldResumeSession: true)
            }
            group.leave()
        }

        group.enter()
        appStateQueue.async { [appState] in
            for index in 0..<iterations {
                appState?.stubbedState = index.isMultiple(of: 2) ? .background : .foreground
            }
            group.leave()
        }

        let producersFinished = expectation(description: "Producers finished")
        group.notify(queue: .global()) { producersFinished.fulfill() }
        wait(for: [producersFinished], timeout: defaultTimeout)

        // After the storm, a clean background → foreground cycle must still
        // recover, proving the effect did not crash, deadlock, or wedge its
        // serial queue.
        appState.stubbedState = .background
        publisher.audioSessionDidBeginInterruption(session)
        publisher.audioSessionDidEndInterruption(session, shouldResumeSession: true)
        appState.stubbedState = .foreground

        wait(for: [sawRecovery], timeout: defaultTimeout)
    }

    // MARK: - Helpers

    private func makeState(
        isActive: Bool = false,
        isInterrupted: Bool = false,
        isRecording: Bool = false,
        isMicrophoneMuted: Bool = false,
        hasRecordingPermission: Bool = false,
        activeSessionIdentifier: String = "",
        audioDeviceModule: AudioDeviceModule? = nil,
        currentRoute: RTCAudioStore.StoreState.AudioRoute = .empty,
        audioSessionConfiguration: RTCAudioStore.StoreState.AVAudioSessionConfiguration = .init(
            category: .soloAmbient,
            mode: .default,
            options: [],
            overrideOutputAudioPort: .none
        ),
        webRTCAudioSessionConfiguration: RTCAudioStore.StoreState.WebRTCAudioSessionConfiguration = .init(
            isAudioEnabled: false,
            useManualAudio: false,
            prefersNoInterruptionsFromSystemAlerts: false
        )
    ) -> RTCAudioStore.StoreState {
        .init(
            isActive: isActive,
            isInterrupted: isInterrupted,
            isRecording: isRecording,
            isMicrophoneMuted: isMicrophoneMuted,
            isMutedSpeechDetectionEnabled: false,
            hasRecordingPermission: hasRecordingPermission,
            activeSessionIdentifier: activeSessionIdentifier,
            audioDeviceModule: audioDeviceModule,
            currentRoute: currentRoute,
            audioSessionConfiguration: audioSessionConfiguration,
            webRTCAudioSessionConfiguration: webRTCAudioSessionConfiguration,
            stereoConfiguration: .init(playout: .init(preferred: false, enabled: false))
        )
    }
}
