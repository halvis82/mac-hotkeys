import Cocoa

func modelTests() {
    suite("Window admission") {
        let active: UInt64 = 5

        test("a window on another Space is admitted without asking AX") {
            expectEqual(WindowLister.admission(of: 1, space: 9, activeSpace: active, vouched: [2], minimized: []), .onSpace)
        }

        test("on the active Space, AX can veto a window it does not vouch for") {
            expectEqual(WindowLister.admission(of: 1, space: active, activeSpace: active, vouched: [2, 3], minimized: []), .skip)
            expectEqual(WindowLister.admission(of: 2, space: active, activeSpace: active, vouched: [2, 3], minimized: []), .onSpace)
        }

        test("an app that gives AX nothing back cannot veto anything") {
            expectEqual(WindowLister.admission(of: 1, space: active, activeSpace: active, vouched: [], minimized: []), .onSpace)
        }

        test("a window with no Space is admitted only if AX says it is minimized") {
            expectEqual(WindowLister.admission(of: 1, space: nil, activeSpace: active, vouched: [1], minimized: []), .skip)
            expectEqual(WindowLister.admission(of: 1, space: nil, activeSpace: active, vouched: [], minimized: [1]), .minimized)
        }

        test("the minimized set does not rescue a vetoed window on the active Space") {
            expectEqual(WindowLister.admission(of: 1, space: active, activeSpace: active, vouched: [2], minimized: [1]), .skip)
        }
    }

    suite("Fullscreen main windows") {
        test("a lone window survives") {
            expectEqual(WindowLister.mainWindows(onFullscreenSpace: [window(1)]).map(\.id), [1])
        }

        test("both halves of a split view survive") {
            let left = window(1, size: CGSize(width: 756, height: 982))
            let right = window(2, size: CGSize(width: 700, height: 982))
            expectEqual(WindowLister.mainWindows(onFullscreenSpace: [left, right]).map(\.id), [1, 2])
        }

        test("helper windows under 40% of the largest are dropped, like Chrome's 941x458") {
            let main = window(1, size: CGSize(width: 1512, height: 982))
            let helper = window(2, size: CGSize(width: 941, height: 458))
            let strip = window(3, size: CGSize(width: 1512, height: 68))
            expectEqual(WindowLister.mainWindows(onFullscreenSpace: [helper, main, strip]).map(\.id), [1])
        }

        test("exactly 40% is kept") {
            let main = window(1, size: CGSize(width: 100, height: 100))
            let edge = window(2, size: CGSize(width: 40, height: 100))
            expectEqual(WindowLister.mainWindows(onFullscreenSpace: [main, edge]).map(\.id), [1, 2])
        }

        test("all zero-sized windows are kept rather than all dropped") {
            let a = window(1, size: .zero), b = window(2, size: .zero)
            expectEqual(WindowLister.mainWindows(onFullscreenSpace: [a, b]).map(\.id), [1, 2])
        }

        test("order is preserved") {
            let a = window(3), b = window(1), c = window(2)
            expectEqual(WindowLister.mainWindows(onFullscreenSpace: [a, b, c]).map(\.id), [3, 1, 2])
        }
    }

    suite("One window per app") {
        test("each app shows once, as its most recent window") {
            let windows = [window(10, key: "a"), window(11, key: "a"), window(12, key: "b")]
            let picked = WindowLister.oneWindowPerApp(windows) { id in id == 11 ? 0 : Int.max }
            expectEqual(picked.map(\.id), [11, 12])
        }

        test("with no history, the first listed window of each app stands for it") {
            let windows = [window(20, key: "a"), window(10, key: "a"), window(30, key: "b")]
            let picked = WindowLister.oneWindowPerApp(windows) { _ in Int.max }
            expectEqual(picked.map(\.id), [20, 30])
        }

        test("apps are ordered by their lowest window id, not by recency, so the grid stays put") {
            let windows = [window(50, key: "late"), window(5, key: "early"), window(60, key: "late")]
            let picked = WindowLister.oneWindowPerApp(windows) { id in id == 60 ? 0 : 1 }
            expectEqual(picked.map(\.appKey), ["early", "late"])
            expectEqual(picked.map(\.id), [5, 60])
        }

        test("Chrome's windows under several pids still group as one app") {
            let windows = [window(1, pid: 10, key: "com.google.Chrome"), window(2, pid: 11, key: "com.google.Chrome")]
            expectEqual(WindowLister.oneWindowPerApp(windows) { _ in Int.max }.count, 1)
        }
    }

    suite("Assembling the row") {
        let noHistory: (CGWindowID) -> Int = { _ in Int.max }

        test("Spaces keep window-server order, fullscreen expands, desktops collapse") {
            let spaces = [desktop(1), fullscreen(2), desktop(3)]
            let bySpace: [UInt64?: [WindowInfo]] = [
                1: [window(11, key: "a"), window(12, key: "b")],
                2: [window(21)],
                3: [window(31, key: "c")],
            ]
            let tiles = WindowLister.assembleTiles(spaces: spaces, bySpace: bySpace, recency: noHistory)
            expectEqual(describe(tiles), ["desk1:11,12", "fs2:21", "desk3:31"])
        }

        test("a split-view Space becomes two tiles") {
            let bySpace: [UInt64?: [WindowInfo]] = [2: [window(22, size: CGSize(width: 700, height: 900)),
                                                       window(21, size: CGSize(width: 800, height: 900))]]
            let tiles = WindowLister.assembleTiles(spaces: [fullscreen(2)], bySpace: bySpace, recency: noHistory)
            expectEqual(describe(tiles), ["fs2:21", "fs2:22"])
        }

        test("empty Spaces are skipped") {
            let tiles = WindowLister.assembleTiles(spaces: [desktop(1), fullscreen(2), desktop(3)],
                                                   bySpace: [3: [window(31)]], recency: noHistory)
            expectEqual(describe(tiles), ["desk3:31"])
        }

        test("minimized windows hang off the first desktop, even an otherwise empty one") {
            let bySpace: [UInt64?: [WindowInfo]] = [
                nil: [window(99, key: "m", minimized: true)],
                3: [window(31, key: "c")],
            ]
            let tiles = WindowLister.assembleTiles(spaces: [fullscreen(2), desktop(1), desktop(3)],
                                                   bySpace: bySpace.merging([2: [window(21)]]) { a, _ in a },
                                                   recency: noHistory)
            expectEqual(describe(tiles), ["fs2:21", "desk1:99", "desk3:31"])
        }

        test("minimized windows are dropped when there is no desktop to hang them on") {
            let tiles = WindowLister.assembleTiles(spaces: [fullscreen(2)],
                                                   bySpace: [nil: [window(99, minimized: true)], 2: [window(21)]],
                                                   recency: noHistory)
            expectEqual(describe(tiles), ["fs2:21"])
        }

        test("a minimized window of an app already on the desktop collapses into that app") {
            let bySpace: [UInt64?: [WindowInfo]] = [
                1: [window(11, key: "a")],
                nil: [window(5, key: "a", minimized: true)],
            ]
            let tiles = WindowLister.assembleTiles(spaces: [desktop(1)], bySpace: bySpace) { id in id == 5 ? 0 : 1 }
            expectEqual(describe(tiles), ["desk1:5"])
        }

        test("desktop windows are sorted by id before collapsing, whatever order they were listed in") {
            let bySpace: [UInt64?: [WindowInfo]] = [1: [window(30, key: "a"), window(10, key: "a")]]
            let tiles = WindowLister.assembleTiles(spaces: [desktop(1)], bySpace: bySpace, recency: noHistory)
            expectEqual(describe(tiles), ["desk1:10"])
        }

        test("an app's key window stands for it on a desktop, whatever the history says") {
            let bySpace: [UInt64?: [WindowInfo]] = [1: [window(10, key: "messages"), window(11, key: "messages"), window(20, key: "notes")]]
            let history: (CGWindowID) -> Int = { $0 == 10 ? 0 : Int.max }
            let plain = WindowLister.assembleTiles(spaces: [desktop(1)], bySpace: bySpace, recency: history)
            expectEqual(describe(plain), ["desk1:10,20"])
            let keyed = WindowLister.assembleTiles(spaces: [desktop(1)], bySpace: bySpace,
                                                   recency: WindowLister.preferring(keyWindows: [11], over: history))
            expectEqual(describe(keyed), ["desk1:11,20"])
        }

        test("a key window elsewhere leaves the history to decide on this desktop") {
            let bySpace: [UInt64?: [WindowInfo]] = [1: [window(10, key: "chrome"), window(11, key: "chrome")], 2: [window(30, key: "chrome")]]
            let history: (CGWindowID) -> Int = { $0 == 11 ? 0 : Int.max }
            let tiles = WindowLister.assembleTiles(spaces: [desktop(1), fullscreen(2)], bySpace: bySpace,
                                                   recency: WindowLister.preferring(keyWindows: [30], over: history))
            expectEqual(describe(tiles), ["desk1:11", "fs2:30"])
        }

        test("windows listed under a Space that no longer exists are ignored") {
            let tiles = WindowLister.assembleTiles(spaces: [desktop(1)],
                                                   bySpace: [1: [window(11)], 77: [window(771)]],
                                                   recency: noHistory)
            expectEqual(describe(tiles), ["desk1:11"])
        }
    }

    suite("Cmd+` cycle order") {
        test("every window of the app in id order, helper slivers dropped") {
            let bySpace: [UInt64?: [WindowInfo]] = [
                2: [window(40, size: CGSize(width: 1512, height: 982)), window(41, size: CGSize(width: 1512, height: 68))],
                1: [window(30), window(10)],
                nil: [window(20, minimized: true)],
            ]
            let ids = WindowLister.cyclableWindows(spaces: [desktop(1), fullscreen(2)], bySpace: bySpace).map(\.id)
            expectEqual(ids, [10, 20, 30, 40])
        }

        test("desktop windows are not size-filtered, since Stage Manager shrinks real ones") {
            let bySpace: [UInt64?: [WindowInfo]] = [
                1: [window(1, size: CGSize(width: 1200, height: 800)), window(2, size: CGSize(width: 131, height: 140))],
            ]
            expectEqual(WindowLister.cyclableWindows(spaces: [desktop(1)], bySpace: bySpace).map(\.id), [1, 2])
        }
    }
}
