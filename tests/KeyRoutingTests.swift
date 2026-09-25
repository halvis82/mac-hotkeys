import Cocoa

func keyRoutingTests() {
    suite("Key routing") {
        let cmd: CGEventFlags = .maskCommand
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]

        test("moon key down and up go to the focus toggle and are swallowed, open or not") {
            for open in [false, true] {
                let down = routeKey(type: .keyDown, code: dndKeyCode, flags: [], switcherOpen: open)
                let up = routeKey(type: .keyUp, code: dndKeyCode, flags: [], switcherOpen: open)
                expectEqual(down, .focusKeyDown)
                expectEqual(up, .focusKeyUp)
                expect(down.swallows && up.swallows)
            }
        }

        test("moon key still counts with modifiers held") {
            expectEqual(routeKey(type: .keyDown, code: dndKeyCode, flags: cmdShift, switcherOpen: false), .focusKeyDown)
        }

        test("Cmd+Tab opens forward, Cmd+Shift+Tab backward, both swallowed") {
            let forward = routeKey(type: .keyDown, code: tabKeyCode, flags: cmd, switcherOpen: false)
            let backward = routeKey(type: .keyDown, code: tabKeyCode, flags: cmdShift, switcherOpen: false)
            expectEqual(forward, .tab(backwards: false))
            expectEqual(backward, .tab(backwards: true))
            expect(forward.swallows && backward.swallows)
        }

        test("Cmd+Tab routes the same while open, so advancing is decided on the main queue") {
            expectEqual(routeKey(type: .keyDown, code: tabKeyCode, flags: cmd, switcherOpen: true), .tab(backwards: false))
        }

        test("plain Tab and Tab key-up are left alone") {
            expectEqual(routeKey(type: .keyDown, code: tabKeyCode, flags: [], switcherOpen: false), .pass)
            expectEqual(routeKey(type: .keyUp, code: tabKeyCode, flags: cmd, switcherOpen: true), .pass)
        }

        test("releasing Command commits only while the switcher is open, and never swallows") {
            let release = routeKey(type: .flagsChanged, code: 55, flags: [], switcherOpen: true)
            expectEqual(release, .commit)
            expect(!release.swallows, "a modifier change must always reach the system")
            expectEqual(routeKey(type: .flagsChanged, code: 55, flags: [], switcherOpen: false), .pass)
        }

        test("a modifier change with Command still down does not commit") {
            expectEqual(routeKey(type: .flagsChanged, code: 56, flags: cmdShift, switcherOpen: true), .pass)
        }

        test("Cmd+` cycles, but not with Control or Option, and not without Command") {
            expectEqual(routeKey(type: .keyDown, code: graveKeyCode, flags: cmd, switcherOpen: false), .cycle)
            expectEqual(routeKey(type: .keyDown, code: graveKeyCode, flags: cmdShift, switcherOpen: false), .cycle)
            expectEqual(routeKey(type: .keyDown, code: graveKeyCode, flags: [.maskCommand, .maskControl], switcherOpen: false), .pass)
            expectEqual(routeKey(type: .keyDown, code: graveKeyCode, flags: [.maskCommand, .maskAlternate], switcherOpen: false), .pass)
            expectEqual(routeKey(type: .keyDown, code: graveKeyCode, flags: [], switcherOpen: false), .pass)
        }

        test("Cmd+` still cycles while the switcher is open") {
            expectEqual(routeKey(type: .keyDown, code: graveKeyCode, flags: cmd, switcherOpen: true), .cycle)
        }

        test("Escape, arrows and digits are only taken while the switcher is open") {
            let closedCodes = [escKeyCode, leftArrowKeyCode, rightArrowKeyCode] + digitKeyCodes + keypadDigitKeyCodes
            for code in closedCodes {
                expectEqual(routeKey(type: .keyDown, code: code, flags: cmd, switcherOpen: false), .pass, "code \(code)")
            }
            expectEqual(routeKey(type: .keyDown, code: escKeyCode, flags: cmd, switcherOpen: true), .cancel)
            expectEqual(routeKey(type: .keyDown, code: leftArrowKeyCode, flags: cmd, switcherOpen: true), .moveWithinDesktop(-1))
            expectEqual(routeKey(type: .keyDown, code: rightArrowKeyCode, flags: cmd, switcherOpen: true), .moveWithinDesktop(1))
        }

        test("number row and keypad digits map to positions 0 through 8") {
            for (position, code) in digitKeyCodes.enumerated() {
                expectEqual(routeKey(type: .keyDown, code: code, flags: cmd, switcherOpen: true), .select(position: position))
            }
            for (position, code) in keypadDigitKeyCodes.enumerated() {
                expectEqual(routeKey(type: .keyDown, code: code, flags: cmd, switcherOpen: true), .select(position: position))
            }
        }

        test("digit key codes are the real US layout codes for 1 to 9") {
            // kVK_ANSI_1 ... kVK_ANSI_9 and kVK_ANSI_Keypad1 ... kVK_ANSI_Keypad9 from HIToolbox.
            expectEqual(digitKeyCodes, [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19])
            expectEqual(keypadDigitKeyCodes, [0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C])
        }

        test("other keys pass through while open, so typing is never eaten") {
            expectEqual(routeKey(type: .keyDown, code: 0, flags: cmd, switcherOpen: true), .pass)   // A
            expectEqual(routeKey(type: .keyDown, code: 29, flags: cmd, switcherOpen: true), .pass)  // 0
            expectEqual(routeKey(type: .keyUp, code: escKeyCode, flags: cmd, switcherOpen: true), .pass)
        }

        test("only pass and commit let the event through") {
            let all: [KeyAction] = [.pass, .focusKeyDown, .focusKeyUp, .commit, .tab(backwards: false),
                                    .cycle, .cancel, .moveWithinDesktop(1), .select(position: 0)]
            expectEqual(all.filter { !$0.swallows }, [.pass, .commit])
        }
    }
}
