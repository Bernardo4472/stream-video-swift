//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import AVFoundation
import Combine
import Foundation
import StreamWebRTC

extension RTCAudioStore {

    /// Converts audio session interruption callbacks into store actions so the
    /// audio pipeline can gracefully pause and resume.
    ///
    /// - Note: Under investigation — both triggers (the audio-session
    ///   publisher and the app-lifecycle publisher) are funneled through
    ///   ``processingQueue`` so the shared ``pendingForegroundRecovery`` flag
    ///   is mutated from a single serial context. This serialization is
    ///   suspected to leave the microphone stopped after backgrounding.
    final class InterruptionsEffect: StoreEffect<RTCAudioStore.Namespace>, @unchecked Sendable {

        @Injected(\.applicationStateAdapter) private var applicationStateAdapter

        private let audioSessionObserver: RTCAudioSessionPublisher
        private let disposableBag = DisposableBag()
        private let processingQueue = OperationQueue(maxConcurrentOperationCount: 1)

        /// `true` when an interruption ended while the app was not active and a
        /// recording restart still needs to run against an active session.
        ///
        /// Accessed only from ``processingQueue``, which serialises reads and
        /// writes.
        private var pendingForegroundRecovery = false

        convenience init(_ source: RTCAudioSession) {
            self.init(.init(source))
        }

        init(_ audioSessionObserver: RTCAudioSessionPublisher) {
            self.audioSessionObserver = audioSessionObserver
            super.init()

            audioSessionObserver
                .publisher
                .receive(on: processingQueue)
                .sink { [weak self] in self?.handle($0) }
                .store(in: disposableBag)

            applicationStateAdapter
                .statePublisher
                .removeDuplicates()
                .filter { $0 == .foreground }
                .receive(on: processingQueue)
                .sink { [weak self] _ in self?.recoverPendingForegroundInterruption() }
                .store(in: disposableBag)
        }

        // MARK: - Private Helpers

        /// Handles the underlying audio session events and dispatches the
        /// appropriate store actions.
        private func handle(
            _ event: RTCAudioSessionPublisher.Event
        ) {
            switch event {
            case .didBeginInterruption:
                dispatcher?.dispatch(.setInterrupted(true))

            case .didEndInterruption(let shouldResumeSession):
                guard
                    state?.isInterrupted == true
                else {
                    return
                }

                var actions: [Namespace.Action] = [
                    .setInterrupted(false)
                ]

                if
                    shouldResumeSession,
                    let state = stateProvider?(),
                    state.audioDeviceModule != nil {
                    let isRecording = state.isRecording
                    let isMicrophoneMuted = state.isMicrophoneMuted

                    if isRecording {
                        actions.append(.setRecording(false))
                        actions.append(.setRecording(true))
                    }

                    actions.append(.setMicrophoneMuted(isMicrophoneMuted))
                }
                dispatcher?.dispatch(actions.map(\.box))

                // WebRTC can only (re)start the input audio unit while the app
                // is active. When the interruption ends while the app is still
                // backgrounded, the recording restart above never actually
                // starts the engine input, leaving the microphone recording
                // silence. Flag a replay for the next foreground transition.
                if applicationStateAdapter.state != .foreground {
                    pendingForegroundRecovery = true
                }

            default:
                break
            }
        }

        /// Replays the recording restart once the app becomes active, recovering
        /// microphone capture that could not start while backgrounded.
        private func recoverPendingForegroundInterruption() {
            guard pendingForegroundRecovery else {
                return
            }
            pendingForegroundRecovery = false

            guard
                let state = stateProvider?(),
                state.isActive,
                state.isRecording
            else {
                return
            }

            // Dispatched asynchronously so the restart runs after WebRTC has
            // reactivated the session on becoming active.
            let actions: [Namespace.Action] = [
                .setRecording(false),
                .setRecording(true),
                .setMicrophoneMuted(state.isMicrophoneMuted)
            ]
            dispatcher?.dispatch(actions.map(\.box))
        }
    }
}
