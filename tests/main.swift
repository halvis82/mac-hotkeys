import Cocoa

// Entry point for `./test.sh`. Unit tests always run. `--live` adds tests against the real
// window server, `--bench` adds before/after timings of the switcher's hot paths, and
// `--navigation` really switches Spaces to check every switch lands on the window picked, and
// `--keys` types real Cmd+Tab and Escape into the installed agent and reads its timings.

let arguments = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

keyRoutingTests()
modelTests()
switcherTests()
windowMenuTests()
focusTests()
thumbnailTests()

if arguments.contains("--live") || arguments.contains("--bench") || arguments.contains("--navigation")
    || arguments.contains("--keys") {
    if screenIsLocked {
        print("\n❌ the screen is locked, so the live, bench and navigation tests cannot run. Unlock and try again.")
        exit(1)
    }
    guard let sky = SkyLight() else {
        print("could not resolve SkyLight symbols")
        exit(1)
    }
    if arguments.contains("--live") { liveTests(sky) }
    if arguments.contains("--bench") { benchmarks(sky) }
    if arguments.contains("--navigation") { navigationTests(sky) }
    if arguments.contains("--keys") { keystrokeTests(sky) }
}

print("\n\(TestRun.failed == 0 ? "✅" : "❌") \(TestRun.passed) passed, \(TestRun.failed) failed")
for failure in TestRun.failures { print("   ❌ \(failure)") }
exit(TestRun.failed == 0 ? 0 : 1)
