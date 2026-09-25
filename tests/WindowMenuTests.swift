import Cocoa

func windowMenuTests() {
    // Shaped like a real Window menu: commands, a separator, more commands, a separator, windows.
    let chrome = ["Minimize", "Zoom", "", "Downloads", "Extensions", "", "New Tab", "New Tab", "Downloads"]

    suite("Window-menu matching") {
        test("only the window list after the last separator is searched") {
            let order = WindowActions.windowMenuCandidates(labels: chrome, windowTitle: "Downloads") { _ in false }
            expectEqual(order, [8], "the Downloads command at index 3 must never be pressed")
        }

        test("unchecked entries come first, the checked current window last") {
            let order = WindowActions.windowMenuCandidates(labels: chrome, windowTitle: "New Tab") { $0 == 6 }
            expectEqual(order, [7, 6])
            let other = WindowActions.windowMenuCandidates(labels: chrome, windowTitle: "New Tab") { $0 == 7 }
            expectEqual(other, [6, 7])
        }

        test("entries that extend the title match, as apps append to it") {
            let labels = ["", "Inbox - Mail (3 messages)"]
            expectEqual(WindowActions.windowMenuCandidates(labels: labels, windowTitle: "Inbox - Mail") { _ in false }, [1])
        }

        test("an entry cut short with an ellipsis matches the full title") {
            let labels = ["", "A very long document ti\u{2026}"]
            let order = WindowActions.windowMenuCandidates(labels: labels, windowTitle: "A very long document title.txt") { _ in false }
            expectEqual(order, [1])
        }

        test("a shorter entry without an ellipsis does not claim a longer title") {
            let labels = ["Zoom", "", "Zoom"]
            expectEqual(WindowActions.windowMenuCandidates(labels: labels, windowTitle: "Zoom Meeting") { _ in false }, [])
        }

        test("the title is trimmed, and an empty or blank title matches nothing") {
            let labels = ["", "Notes"]
            expectEqual(WindowActions.windowMenuCandidates(labels: labels, windowTitle: "  Notes ") { _ in false }, [1])
            expectEqual(WindowActions.windowMenuCandidates(labels: labels, windowTitle: "   ") { _ in false }, [])
            expectEqual(WindowActions.windowMenuCandidates(labels: labels, windowTitle: "") { _ in false }, [])
        }

        test("a menu without separators is searched whole") {
            expectEqual(WindowActions.windowMenuCandidates(labels: ["Report", "Other"], windowTitle: "Report") { _ in false }, [0])
        }

        test("a menu ending in a separator has no window list, so nothing matches") {
            expectEqual(WindowActions.windowMenuCandidates(labels: ["Report", ""], windowTitle: "Report") { _ in false }, [])
        }

        test("the checkmark is only asked about entries that match") {
            var asked: [Int] = []
            _ = WindowActions.windowMenuCandidates(labels: chrome, windowTitle: "New Tab") { asked.append($0); return false }
            expectEqual(asked.sorted(), [6, 7])
        }
    }

    suite("Reaching a window that is not the app's most recent") {
        test("the app merely reporting itself active is not enough to press the Window menu") {
            // The bug: Chrome active, screen still on the desktop, about to move to Chrome's
            // most recent window elsewhere. A press here was swallowed by that move.
            expect(!WindowActions.activationHasLanded(activeSpace: 9, origin: 9, focusedWindowSpace: 2100))
        }

        test("once the Space has started changing, a press is queued behind it and lands") {
            expect(WindowActions.activationHasLanded(activeSpace: 2100, origin: 9, focusedWindowSpace: 2100))
            expect(WindowActions.activationHasLanded(activeSpace: 2100, origin: 9, focusedWindowSpace: nil))
        }

        test("when the app's recent window is right here, nothing will move, so press at once") {
            expect(WindowActions.activationHasLanded(activeSpace: 9, origin: 9, focusedWindowSpace: 9))
        }

        test("an unreadable focused window with no movement yet means wait") {
            expect(!WindowActions.activationHasLanded(activeSpace: 9, origin: 9, focusedWindowSpace: nil))
        }
    }
}
