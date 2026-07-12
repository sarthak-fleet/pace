//
//  PaceTestEnvironment.swift
//  leanring-buddyTests
//
//  Shared test-environment probe. The only thing it knows how to
//  answer today is "are we running inside CI?" — used to skip the
//  handful of tests whose slow part is real elapsed wall-clock time
//  spent waiting on hardware that does not exist on a headless
//  GitHub Actions runner (e.g. the CoreAudio HAL blocking when an
//  `AVAudioEngine` tries to open a non-existent microphone).
//
//  Why this exists
//  ---------------
//  A handful of tests call `.start()` on the always-listening wake-word
//  spotter, which brings up a real `AVAudioEngine` + `SFSpeechRecognizer`
//  and blocks on the audio HAL. On developer Macs the HAL answers
//  instantly; on the GitHub `macos-latest` runner there is no audio
//  input device, so the HAL retries on a ~30-second timeout loop and the
//  whole `xcodebuild test-without-building` step wedges for the full CI
//  time budget (observed: 30m34s) before failing. These tests assert
//  lifecycle bookkeeping (`isRunning`, task-cancelled), NOT audio I/O,
//  so skipping them in CI loses no meaningful coverage — they still run
//  on every developer machine and in `scripts/test-pace.sh`.
//
//  Contract
//  --------
//  `isRunningInCI` is driven ONLY by the `PACE_CI` environment variable,
//  which CI sets to `1`. `scripts/test-pace.sh` deliberately does NOT set
//  it, so the local suite always exercises the full test set. A gated
//  test must be one whose slow part is real elapsed time or missing
//  hardware — never merely "slow-ish" pure-CPU logic.
//

import Foundation

enum PaceTestEnvironment {
    /// True when the test process was launched by CI. CI sets the
    /// `PACE_CI` environment variable to `1`; nothing else sets it, so
    /// this is `false` on every developer machine and in
    /// `scripts/test-pace.sh`.
    static var isRunningInCI: Bool {
        ProcessInfo.processInfo.environment["PACE_CI"] == "1"
    }
}
