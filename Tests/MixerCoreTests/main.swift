import Foundation

var failures = 0
var skipped = 0
struct TestSkipped: Error { let reason: String }
func failure(_ message: String, file: StaticString, line: UInt) { failures += 1; print("FAIL \(file):\(line): \(message)") }
func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { failure("Expected true", file: file, line: line) } }
func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { checkTrue(!value, file: file, line: line) }
func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { failure("\(a) != \(b)", file: file, line: line) } }
func checkNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a == b { failure("Values should differ", file: file, line: line) } }
func checkEqual<T: BinaryFloatingPoint>(_ a: T, _ b: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(abs(a-b) <= accuracy, file: file, line: line) }
func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { checkTrue(value == nil, file: file, line: line) }
func checkGreater<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a > b, file: file, line: line) }
func checkLess<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a < b, file: file, line: line) }
func checkLessEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a <= b, file: file, line: line) }
struct MissingValue: Error {}
func require<T>(_ value: T?) throws -> T { guard let value else { throw MissingValue() }; return value }

let identity = IdentityTests(), dsp = DSPTests(), prefs = PreferencesTests()
let tests: [(String, () throws -> Void)] = [
    ("Dragging batches persistence and unity bypass", LifecycleTests().testDraggingDefersSaveAndKeepsUnityUntilFinished),
    ("Pending preferences flush and scoped removal", LifecycleTests().testPendingSaveIsFlushedOnPauseAndCannotReturnAfterResetOrUninstall),
    ("Repeated discovery errors retain route choices", LifecycleTests().testRepeatedDiscoveryFailuresStopControlButRetainRouteChoices),
    ("Discovery grace rejects unsafe routes", LifecycleTests().testDiscoveryGraceStillStopsFaultyOrDisconnectedRoutes),
    ("Discovery grace is time bounded", LifecycleTests().testDiscoveryGraceHasTimeLimit),
    ("Stall backlog crossfade and ring wraps", BridgeTests().testStallBacklogRecoversWithSmoothCrossfadeAcrossWraps),
    ("Repeated stalls during crossfade", BridgeTests().testRepeatedStallsDuringCrossfadeRemainContinuous),
    ("Hardware-based output icons", RoutingTests().testOutputIconsUseHardwareMetadata),
    ("Idle process retention rejects reuse", identity.testRetainedIdleProcessRequiresOriginalObjectAndLifetime),
    ("Idle hidden app retains attenuation", LifecycleTests().testHiddenIdleAppKeepsAttenuation),
    ("Slider events avoid discovery and repeated persistence", LifecycleTests().testSliderUpdatesDoNotScanOrWriteForEveryEvent),
    ("Unity boundary retains the session", LifecycleTests().testUnityBoundaryDoesNotChurnSessions),
    ("Temporary discovery preserves healthy sessions", LifecycleTests().testTemporaryDiscoveryFailurePreservesHealthyControl),
    ("New app shows connecting state", LifecycleTests().testNewAppPublishesConnecting),
    ("Browser helpers", identity.testBrowserHelperUsesOuterApplication),
    ("Ambiguous WebKit ownership", identity.testSharedWebKitHelpersStaySeparateWithoutOwner),
    ("Process lifetime and PID reuse", identity.testProcessLifetimeRejectsRecycledAndUnknownPIDs),
    ("Wine PID reuse", identity.testUnknownWineProcessesDoNotCollideOrPersist),
    ("Separate Wine bottles", identity.testSameGameDifferentBottlesStaysSeparate),
    ("Game relaunch identity", identity.testGameIdentitySurvivesRelaunch),
    ("Wine metadata and ambiguous executables", WineMetadataTests().testWineMetadataAndAmbiguousExecutables),
    ("Malformed and truncated Wine metadata", WineMetadataTests().testMalformedMetadataNeverReturnsPartialIdentity),
    ("Independent app attenuation", dsp.testStereoAttenuationAndIndependentSessions),
    ("Click-free mute ramp", dsp.testMuteRampsWithoutClickThenOutputsZero),
    ("Microphone exclusion and planar buffers", dsp.testPhysicalInputChannelsAreSkippedAndPlanarIsSupported),
    ("Mono/stereo mapping", dsp.testMonoAndStereoMapping),
    ("Missing and invalid input", dsp.testMissingInputClearsOutputAndNonFiniteSamplesAreContained),
    ("Unsupported layout rejection", dsp.testInvalidLayoutsAreRejected),
    ("Unmute ramp and live layout failure", dsp.testUnmuteRampsAndLayoutChangesClearOutput),
    ("Mute restoration", prefs.testMuteRestoresLevelAndSliderUnmutes),
    ("Persistence and scoped removal", prefs.testPersistenceAndUninstallDoNotTouchOtherDomains),
    ("Preference removal failure", prefs.testRemovalFailureIsReportedAndWritesStayDisabled),
    ("Recently active and muted rows", prefs.testVisibilityRetainsMutedRunningAppAndRecentIdleApp),
    ("Scoped file cleanup and symlink safety", UninstallTests().testCleanupIsScopedAndDoesNotFollowSymlinks),
    ("Independent sessions, pause, and shutdown", LifecycleTests().testIndependentSessionsPauseAndShutdown),
    ("Permission failure and explicit retry", LifecycleTests().testPermissionFailureAndExplicitRetry),
    ("Output changes, sleep, and device loss", LifecycleTests().testOutputChangeSleepAndDeviceLoss),
    ("Default switch preserves unrelated routing", LifecycleTests().testDefaultOutputSwitchPreservesUnchangedExplicitRoute),
    ("Default switch preserves unrelated failure state", LifecycleTests().testUnrelatedDefaultSwitchDoesNotRetryFailedExplicitRoute),
    ("Stalled callback and layout recovery", LifecycleTests().testStalledCallbackAndLayoutFaultRestorePlayback),
    ("Muted app without audio objects", LifecycleTests().testMutedRunningAppSurvivesAudioObjectRemoval),
    ("Selected-process capture across outputs", RoutingTests().testTapIncludesOnlySelectedProcessesAcrossOutputs),
    ("Saved output migration, relaunch, reset and cleanup", RoutingTests().testOldPreferencesAndSavedOutputSurviveRelaunch),
    ("Bluetooth mono layout and sample-rate validation", RoutingTests().testMonoBluetoothLayoutExcludesMicrophoneAndUsesAggregateRate),
    ("Malformed hardware sizes and channel overflow", RoutingTests().testMalformedHardwareMetadataIsRejected),
    ("Independent routing at 100%, pause and bypass", LifecycleTests().testExplicitOutputAtUnityIsIndependentAndPauseRestoresOriginal),
    ("Disconnected output and UID reconnect", LifecycleTests().testDisconnectedRouteRestoresOriginalAndReconnectsByUID),
    ("Bluetooth profile and source-output changes", LifecycleTests().testBluetoothProfileAndSourceChangesRebuildOnlyAffectedRoute),
    ("Untouched apps stay on their original output", LifecycleTests().testSystemOutputHandlesGameStillBoundToAnotherDevice),
    ("Independent capture and render chunks across ring wraps", BridgeTests().testIndependentCallbackSizesAndChannelMapping),
    ("Concurrent capture and playback sample ordering", BridgeTests().testConcurrentCaptureAndPlayback),
    ("Buffered gain ramp and mute", BridgeTests().testGainMuteAndUnmute),
    ("Queue startup, idle and bounds failures", BridgeTests().testStartupIdleAndBounds),
    ("Capture-only layout excludes physical audio", RoutingTests().testCaptureOnlyLayout),
    ("Apple engine offline 48/44.1 conversion", PlaybackTests().testAppleSampleRateConversion),
    ("Unavailable audio components restore playback", PlaybackTests().testUnavailableComponentsFailWithoutStartingAudio),
    ("Apple engine mono mapping and alias rejection", PlaybackTests().testMonoAndAntiAliasing),
    ("Apple engine mute and independent sessions", PlaybackTests().testMuteAndIndependentSessions),
    ("Bounded playback clock recovery", PlaybackTests().testClockRecovery),
    ("Ten-minute independent-clock playback simulation", PlaybackTests().testSustainedPlayback)
]
for (name, body) in tests {
    let before = failures
    do { try body() }
    catch let skip as TestSkipped { skipped += 1; print("SKIP \(name): \(skip.reason)"); continue }
    catch { failures += 1; print("FAIL \(name): \(error)") }
    if failures == before { print("PASS \(name)") }
}
print("\(tests.count) scenarios; \(failures) failed assertions; \(skipped) skipped")
exit(failures == 0 ? 0 : 1)
