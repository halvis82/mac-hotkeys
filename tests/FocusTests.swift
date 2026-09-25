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

    suite("Moon key shortcut names") {
        func json(_ text: String) -> Data { text.data(using: .utf8)! }

        test("names come from the config file") {
            let names = MoonKeyShortcuts.parse(json(#"{"tap": "My DND on", "hold": "My Work on", "off": "My Focus off"}"#))
            expectEqual(names, MoonKeyShortcuts(tap: "My DND on", hold: "My Work on", off: "My Focus off"))
        }

        test("any name left out, blank or not a string keeps its default") {
            let names = MoonKeyShortcuts.parse(json(#"{"tap": "Work on", "hold": "  ", "off": 3}"#))
            expectEqual(names, MoonKeyShortcuts(tap: "Work on"))
        }

        test("names are trimmed") {
            expectEqual(MoonKeyShortcuts.parse(json(#"{"off": "  Focus off \n"}"#))?.off, "Focus off")
        }

        test("a file that is not a JSON object is rejected, so the defaults are used") {
            for text in ["", "not json", "[1, 2]", "\"tap\""] {
                expect(MoonKeyShortcuts.parse(json(text)) == nil, "\(text) was accepted")
            }
        }
    }

    suite("What a moon key press does") {
        test("holding with Do Not Disturb on switches to the hold mode, not off") {
            // The reported bug: DND on, hold, and it turned DND off instead.
            expectEqual(moonKeyAction(for: .hold, in: .tapMode), .hold)
        }

        test("holding with the hold mode already on turns it off") {
            expectEqual(moonKeyAction(for: .hold, in: .holdMode), .off)
        }

        test("holding with nothing on, or a mode set elsewhere, turns the hold mode on") {
            expectEqual(moonKeyAction(for: .hold, in: .off), .hold)
            expectEqual(moonKeyAction(for: .hold, in: .other), .hold)
        }

        test("tapping turns off whatever is on, and otherwise turns the tap mode on") {
            expectEqual(moonKeyAction(for: .tap, in: .off), .tap)
            for state: FocusState in [.tapMode, .holdMode, .other] {
                expectEqual(moonKeyAction(for: .tap, in: state), .off, "\(state)")
            }
        }
    }

    suite("Which Focus is on") {
        func json(_ text: String) -> Data { text.data(using: .utf8)! }
        let dnd = "com.apple.donotdisturb.mode.default"
        let custom = "8C1D-custom"

        test("the file names the mode that is on") {
            let text = #"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}"#
            expectEqual(parseFocusReading(json(text)), .on(mode: dnd))
            expectEqual(parseFocusReading(json(#"{"data":[{"storeAssertionRecords":[]}]}"#)), .off)
            expect(parseFocusReading(json("not json")) == nil)
        }

        test("a mode is recognized by the identifier learned for it") {
            expectEqual(classifyFocus(.on(mode: dnd), tapMode: dnd, holdMode: custom, lastKnown: .off), .tapMode)
            expectEqual(classifyFocus(.on(mode: custom), tapMode: dnd, holdMode: custom, lastKnown: .off), .holdMode)
            expectEqual(classifyFocus(.on(mode: "work"), tapMode: dnd, holdMode: custom, lastKnown: .holdMode), .other)
            expectEqual(classifyFocus(.off, tapMode: dnd, holdMode: custom, lastKnown: .holdMode), .off)
        }

        test("before a mode's identifier is learned, what the agent last turned on stands in") {
            expectEqual(classifyFocus(.on(mode: custom), tapMode: nil, holdMode: nil, lastKnown: .holdMode), .holdMode)
            expectEqual(classifyFocus(.on(mode: dnd), tapMode: nil, holdMode: nil, lastKnown: .tapMode), .tapMode)
            expectEqual(classifyFocus(.on(mode: dnd), tapMode: nil, holdMode: nil, lastKnown: .off), .other)
        }

        test("without the file, what the agent last did decides") {
            expectEqual(classifyFocus(nil, tapMode: dnd, holdMode: custom, lastKnown: .tapMode), .tapMode)
            expectEqual(classifyFocus(nil, tapMode: nil, holdMode: nil, lastKnown: .off), .off)
        }

        test("the reported case end to end: Do Not Disturb on, hold, goes to the hold mode") {
            let state = classifyFocus(.on(mode: dnd), tapMode: dnd, holdMode: custom, lastKnown: .off)
            expectEqual(moonKeyAction(for: .hold, in: state), .hold)
            // and without Full Disk Access, when the agent had turned DND on itself
            expectEqual(moonKeyAction(for: .hold, in: classifyFocus(nil, tapMode: nil, holdMode: nil, lastKnown: .tapMode)), .hold)
        }
    }
}
