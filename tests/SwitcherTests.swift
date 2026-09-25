import Cocoa

func switcherTests() {
    // Row used throughout: fullscreen A, a desktop with three apps, fullscreen B, fullscreen C.
    let deskSpace = desktop(9)
    let row: [Tile] = [
        .window(space: fullscreen(1), window: window(100, key: "a")),
        .desktop(space: deskSpace, windows: [window(200, key: "x"), window(201, key: "y"), window(202, key: "z")]),
        .window(space: fullscreen(2), window: window(300, key: "b")),
        .window(space: fullscreen(3), window: window(400, key: "c")),
    ]

    suite("Recency") {
        test("rank is position in the history, unseen windows last") {
            let mru = tracker([3, 1, 2])
            expectEqual(mru.rank(of: 3), 0)
            expectEqual(mru.rank(of: 2), 2)
            expectEqual(mru.rank(of: 42), Int.max)
        }

        test("recording again moves a window to the front without duplicating it") {
            let mru = tracker([1, 2, 3])
            mru.record(3)
            expectEqual([1, 2, 3].map(mru.rank(of:)), [1, 2, 0])
        }

        test("history is capped at 60") {
            let mru = MRUTracker()
            for id in 1...100 { mru.record(CGWindowID(id)) }
            expectEqual(mru.rank(of: 100), 0)
            expectEqual(mru.rank(of: 41), 59)
            expectEqual(mru.rank(of: 40), Int.max)
        }

        test("opening lands on the most recent window that is not the current one") {
            expectEqual(tracker([300, 100]).initialSelection(tiles: row, current: 300), 0)
            expectEqual(tracker([300, 400, 100]).initialSelection(tiles: row, current: 300), 3)
        }

        test("windows no longer in the row are skipped over in the history") {
            expectEqual(tracker([300, 999, 201]).initialSelection(tiles: row, current: 300), 1)
        }

        test("with no history it falls back to the tile after the current one, wrapping") {
            expectEqual(MRUTracker().initialSelection(tiles: row, current: 300), 3)
            expectEqual(MRUTracker().initialSelection(tiles: row, current: 400), 0)
        }

        test("with no history and no known current window it starts at the first tile") {
            expectEqual(MRUTracker().initialSelection(tiles: row, current: nil), 0)
            expectEqual(MRUTracker().initialSelection(tiles: [row[0]], current: 100), 0)
        }

        test("inside a desktop, the most recent other window is preselected") {
            let windows = row[1].windows
            expectEqual(tracker([202, 201]).preferredWindowIndex(in: windows, current: nil), 2)
            expectEqual(tracker([202, 201]).preferredWindowIndex(in: windows, current: 202), 1)
            expectEqual(MRUTracker().preferredWindowIndex(in: windows, current: nil), 0)
        }
    }

    suite("Switcher selection") {
        test("Cmd+Tab and release flips back to the previous window") {
            let model = SwitcherModel(tiles: row, current: 300, mru: tracker([300, 100]), backwards: false)
            expectEqual(model.selected, 0)
            expectEqual(model.currentWindow?.id, 100)
        }

        test("opening with Shift starts one step back from the current window, not from recency") {
            let model = SwitcherModel(tiles: row, current: 300, mru: tracker([300, 400]), backwards: true)
            expectEqual(model.selected, 1)
        }

        test("opening with Shift from the first tile wraps to the last") {
            let model = SwitcherModel(tiles: row, current: 100, mru: MRUTracker(), backwards: true)
            expectEqual(model.selected, 3)
        }

        test("opening with Shift and an unknown current window behaves as if on the first tile") {
            let model = SwitcherModel(tiles: row, current: nil, mru: MRUTracker(), backwards: true)
            expectEqual(model.selected, 3)
        }

        test("Tab and Shift+Tab wrap both ways") {
            var model = SwitcherModel(tiles: row, current: 100, mru: tracker([400]), backwards: false)
            expectEqual(model.selected, 3)
            expect(model.advance(by: 1))
            expectEqual(model.selected, 0)
            expect(model.advance(by: -1))
            expectEqual(model.selected, 3)
            for _ in 0..<4 { _ = model.advance(by: 1) }
            expectEqual(model.selected, 3, "a full lap comes back to the same tile")
        }

        test("an empty model ignores everything") {
            var model = SwitcherModel()
            expect(!model.advance(by: 1))
            expect(!model.select(position: 0))
            expect(!model.moveWithinDesktop(by: 1))
            expect(!model.point(atTile: 0, icon: nil))
            expect(model.currentWindow == nil)
        }

        test("each desktop starts on its most recent other window") {
            let model = SwitcherModel(tiles: row, current: 100, mru: tracker([201]), backwards: false)
            expectEqual(model.desktopIndex(ofSpace: deskSpace.id), 1)
            expectEqual(model.currentWindow?.id, 201)
        }

        test("arrows move within a desktop and stop at the ends") {
            var model = SwitcherModel(tiles: row, current: 100, mru: tracker([200]), backwards: false)
            expectEqual(model.selected, 1)
            expect(model.moveWithinDesktop(by: -1))
            expectEqual(model.currentWindow?.id, 200, "already at the left end")
            _ = model.moveWithinDesktop(by: 1); _ = model.moveWithinDesktop(by: 1); _ = model.moveWithinDesktop(by: 1)
            expectEqual(model.currentWindow?.id, 202, "stopped at the right end")
            expectEqual(model.selected, 1, "never spills into the next tile")
        }

        test("arrows do nothing on a fullscreen tile or a single-app desktop") {
            var model = SwitcherModel(tiles: row, current: 100, mru: tracker([300]), backwards: false)
            expect(!model.moveWithinDesktop(by: 1))
            let lone: [Tile] = [.desktop(space: desktop(4), windows: [window(1)]), row[0]]
            var single = SwitcherModel(tiles: lone, current: 100, mru: MRUTracker(), backwards: false)
            expectEqual(single.selected, 0)
            expect(!single.moveWithinDesktop(by: 1))
        }

        test("desktop picks survive moving away and back") {
            var model = SwitcherModel(tiles: row, current: 100, mru: tracker([200]), backwards: false)
            _ = model.moveWithinDesktop(by: 1)
            _ = model.advance(by: 1)
            _ = model.advance(by: -1)
            expectEqual(model.currentWindow?.id, 201)
        }

        test("number keys jump to a tile and ignore numbers past the end") {
            var model = SwitcherModel(tiles: row, current: 100, mru: MRUTracker(), backwards: false)
            expect(model.select(position: 2))
            expectEqual(model.selected, 2)
            expect(!model.select(position: 4))
            expect(!model.select(position: -1))
            expectEqual(model.selected, 2)
        }

        test("the mouse picks a tile, and an icon inside a desktop") {
            var model = SwitcherModel(tiles: row, current: 100, mru: MRUTracker(), backwards: false)
            expect(model.point(atTile: 1, icon: 2))
            expectEqual(model.currentWindow?.id, 202)
            expect(model.point(atTile: 3, icon: 0), "an icon on a fullscreen tile is ignored, the tile is not")
            expectEqual(model.currentWindow?.id, 400)
            expect(model.point(atTile: 1, icon: 9), "an out of range icon keeps the desktop's own pick")
            expectEqual(model.currentWindow?.id, 202)
            expect(!model.point(atTile: 7, icon: nil))
        }
    }

    suite("Switcher layout") {
        func view(_ tiles: [Tile]) -> SwitcherView {
            let view = SwitcherView()
            view.tiles = tiles
            return view
        }

        test("a few tiles draw at full size") {
            let v = view(row)
            let size = v.layoutSize(maxWidth: 1422)
            expectEqual(v.tileWidth, 300)
            expectEqual(size.width, CGFloat(1296)) // 24*2 padding + 4*300 tiles + 3*16 gaps
            expectEqual(size.height, CGFloat(268)) // 24*2 padding + 190 tile + 30 label
        }

        test("many tiles shrink to fit, down to a floor of 96") {
            for count in 1...40 {
                let v = view(Array(repeating: row[0], count: count))
                let size = v.layoutSize(maxWidth: 1422)
                if v.tileWidth > 96 {
                    expect(size.width <= 1422 + 0.001, "\(count) tiles overflow: \(size.width)")
                }
                expect(v.tileWidth >= 96 && v.tileWidth <= 300, "\(count) tiles gave width \(v.tileWidth)")
            }
        }

        test("layout is recomputed from scratch each time, not shrunk cumulatively") {
            let v = view(Array(repeating: row[0], count: 30))
            _ = v.layoutSize(maxWidth: 1422)
            v.tiles = row
            _ = v.layoutSize(maxWidth: 1422)
            expectEqual(v.tileWidth, 300)
        }

        test("the center of each tile hits that tile") {
            let v = view(row)
            _ = v.layoutSize(maxWidth: 1422)
            for index in row.indices where !row[index].isDesktop {
                let rect = v.tileRect(index)
                let hit = v.hit(NSPoint(x: rect.midX, y: rect.midY))
                expectEqual(hit?.tile, index)
                expect(hit?.icon == nil)
            }
        }

        test("each icon in a desktop tile hits that icon") {
            let v = view(row)
            _ = v.layoutSize(maxWidth: 1422)
            let rects = v.iconRects(count: 3, in: v.tileRect(1))
            for (index, rect) in rects.enumerated() {
                let hit = v.hit(NSPoint(x: rect.midX, y: rect.midY))
                expectEqual(hit?.tile, 1)
                expectEqual(hit?.icon, index)
            }
        }

        test("points outside every tile hit nothing") {
            let v = view(row)
            _ = v.layoutSize(maxWidth: 1422)
            expect(v.hit(NSPoint(x: 1, y: 1)) == nil)
            expect(v.hit(NSPoint(x: v.tileRect(3).maxX + 40, y: v.tileRect(3).midY)) == nil)
        }

        test("desktop icons stay inside their tile and never overlap, for any count") {
            let v = view(row)
            for width: CGFloat in [96, 150, 300] {
                let tile = NSRect(x: 0, y: 0, width: width, height: 190)
                for count in 1...24 {
                    let rects = v.iconRects(count: count, in: tile)
                    expectEqual(rects.count, count)
                    for rect in rects {
                        expect(tile.contains(rect), "\(count) icons at width \(width): \(rect) leaves \(tile)")
                    }
                    for i in rects.indices { for j in rects.indices where j > i {
                        expect(!rects[i].intersects(rects[j]), "\(count) icons at width \(width) overlap")
                    } }
                }
            }
        }

        test("grids that already fit keep exactly the layout they always had") {
            // The original formula, before icons could shrink to fit.
            func original(count: Int, in rect: NSRect) -> (rects: [NSRect], fits: Bool) {
                let iconSize: CGFloat = min(52, rect.width / 5.2)
                let spacing: CGFloat = 9
                let perRow = max(1, min(count, Int((rect.width - 16) / (iconSize + spacing))))
                let rows = Int(ceil(Double(count) / Double(perRow)))
                let gridHeight = CGFloat(rows) * iconSize + CGFloat(rows - 1) * spacing
                var rects: [NSRect] = []
                for index in 0..<count {
                    let row = index / perRow, column = index % perRow
                    let itemsInRow = min(perRow, count - row * perRow)
                    let rowWidth = CGFloat(itemsInRow) * iconSize + CGFloat(itemsInRow - 1) * spacing
                    rects.append(NSRect(x: rect.midX - rowWidth / 2 + CGFloat(column) * (iconSize + spacing),
                                        y: rect.midY + gridHeight / 2 - CGFloat(row + 1) * iconSize - CGFloat(row) * spacing,
                                        width: iconSize, height: iconSize))
                }
                return (rects, gridHeight <= rect.height)
            }
            let v = view(row)
            var compared = 0
            for width in stride(from: CGFloat(96), through: 300, by: 17) {
                let tile = NSRect(x: 40, y: 54, width: width, height: 190)
                for count in 1...24 {
                    let before = original(count: count, in: tile)
                    guard before.fits else { continue }
                    expectEqual(v.iconRects(count: count, in: tile), before.rects, "\(count) icons at width \(width)")
                    compared += 1
                }
            }
            expect(compared > 100, "only \(compared) layouts compared")
        }

        test("the view's current window agrees with the model's") {
            var model = SwitcherModel(tiles: row, current: 100, mru: MRUTracker(), backwards: false)
            let v = view(row)
            for step in 0..<8 {
                if step == 3 { _ = model.moveWithinDesktop(by: 1) }
                v.selected = model.selected
                v.desktopSelection = model.desktopSelection
                expectEqual(v.currentWindow()?.id, model.currentWindow?.id)
                _ = model.advance(by: 1)
            }
        }
    }
}
