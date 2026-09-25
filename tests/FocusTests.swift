import Cocoa

func focusTests() {
    suite("Focus state parsing") {
        func json(_ text: String) -> Data { text.data(using: .utf8)! }

        test("no assertion records means no Focus") {
            expectEqual(parseFocusAssertions(json(#"{"data":[{"storeAssertionRecords":[]}]}"#)), false)
        }

        test("any assertion record means a Focus is on") {
            let text = #"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}"#
            expectEqual(parseFocusAssertions(json(text)), true)
        }

        test("only the first data entry counts") {
            let text = #"{"data":[{"storeAssertionRecords":[]},{"storeAssertionRecords":[{}]}]}"#
            expectEqual(parseFocusAssertions(json(text)), false)
        }

        test("anything unreadable is unknown, never off") {
            for text in ["", "not json", "[]", #"{"data":[]}"#, #"{"data":[{}]}"#, #"{"data":"x"}"#,
                         #"{"data":[{"storeAssertionRecords":"x"}]}"#] {
                expect(parseFocusAssertions(json(text)) == nil, "\(text) should be unknown")
            }
        }
    }

    suite("Moon key tap versus hold") {
        final class Counts { var taps = 0; var holds = 0 }

        func detector(_ counts: Counts) -> TapHoldDetector {
            TapHoldDetector(threshold: 0.08, onTap: { counts.taps += 1 }, onHold: { counts.holds += 1 })
        }

        test("a quick press is a tap") {
            let counts = Counts(), key = detector(counts)
            key.keyDown(); key.keyUp()
            runMainLoop(for: 0.15)
            expectEqual(counts.taps, 1); expectEqual(counts.holds, 0)
        }

        test("holding past the threshold fires the hold while still down, and release adds no tap") {
            let counts = Counts(), key = detector(counts)
            key.keyDown()
            runMainLoop(for: 0.15)
            expectEqual(counts.holds, 1, "the hold should not wait for release")
            key.keyUp()
            runMainLoop(for: 0.05)
            expectEqual(counts.taps, 0); expectEqual(counts.holds, 1)
        }

        test("key repeat while held does not restart the timer or double fire") {
            let counts = Counts(), key = detector(counts)
            key.keyDown()
            runMainLoop(for: 0.05)
            key.keyDown(); key.keyDown()
            runMainLoop(for: 0.05)
            expectEqual(counts.holds, 1, "repeat must not push the hold back")
            key.keyUp()
            runMainLoop(for: 0.12)
            expectEqual(counts.holds, 1); expectEqual(counts.taps, 0)
        }

        test("a stray key-up without a key-down does nothing") {
            let counts = Counts(), key = detector(counts)
            key.keyUp()
            runMainLoop(for: 0.1)
            expectEqual(counts.taps, 0); expectEqual(counts.holds, 0)
        }

        test("tap then hold in a row are told apart") {
            let counts = Counts(), key = detector(counts)
            key.keyDown(); key.keyUp()
            key.keyDown()
            runMainLoop(for: 0.15)
            key.keyUp()
            runMainLoop(for: 0.05)
            expectEqual(counts.taps, 1); expectEqual(counts.holds, 1)
        }
    }
}
