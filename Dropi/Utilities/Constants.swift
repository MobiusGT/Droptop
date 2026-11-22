import AppKit
import Foundation

enum ScreenEdge: String, CaseIterable, Sendable {
    case left
    case right
}

enum Constants {
    enum Shelf {
        static let width: CGFloat = 282
        static let emptyHeight: CGFloat = 204
        static let minPopulatedHeight: CGFloat = 176
        static let maxPopulatedHeight: CGFloat = 392
        static let chromeHeight: CGFloat = 114
        static let rowHeight: CGFloat = 52
        static let stackSpacing: CGFloat = 10
        static let cascadeStepX: CGFloat = 28
        static let settingsWidth: CGFloat = 336
        static let settingsHeight: CGFloat = 560
        static let cornerRadius: CGFloat = 16
        static let padding: CGFloat = 10
        static let edgeMargin: CGFloat = 8
        /// Default collapsed width when Auto Hide shows raw shelf edge (~80% hidden).
        static let defaultAutoHideWidth: CGFloat = 56
        static let peekDelay: TimeInterval = 0.45
        static let postDropPeekGrace: TimeInterval = 1.10

        static func preferredHeight(forItemCount count: Int) -> CGFloat {
            guard count > 0 else { return emptyHeight }
            let raw = chromeHeight + CGFloat(count) * rowHeight
            return min(max(raw, minPopulatedHeight), maxPopulatedHeight)
        }

        static func autoHideVisibleWidth(prettyTab: Bool, style: AutoHideTabStyle) -> CGFloat {
            guard prettyTab else { return defaultAutoHideWidth }
            return style.collapsedWidth
        }
    }

    enum Trigger {
        static let dragMovementThreshold: CGFloat = 6.0
        static let outerEdgeImmediateZone: CGFloat = 4.0
        static let outerEdgeZone: CGFloat = 20.0
        static let sharedEdgeZone: CGFloat = 8.0
        static let outerImmediateDwell: TimeInterval = 0.06
        static let outerNormalDwell: TimeInterval = 0.14
        static let sharedEdgeDwell: TimeInterval = 0.25
        static let rearmDistance: CGFloat = 70.0
        static let indicatorProximityZone: CGFloat = 240.0
        static let watchdogInterval: TimeInterval = 0.05
        static let dockDragRecoveryInterval: TimeInterval = 0.15
    }

    enum Thumbnail {
        static let size = CGSize(width: 96, height: 96)
    }
}

/// Pure, testable geometry solver for stacking multiple shelves along the left or right screen edge,
/// re-anchoring dragged shelves to either edge, and computing zero-bleed Auto-Hide frames.
enum ShelfLayoutSolver {
    static func dockedFrame(
        size: NSSize,
        edge: ScreenEdge,
        preferredCenterY: CGFloat,
        visibleFrame: NSRect,
        existingFramesOnSameEdge: [NSRect]
    ) -> NSRect {
        let margin = Constants.Shelf.edgeMargin
        let gap = Constants.Shelf.stackSpacing

        let baseX: CGFloat = (edge == .left)
            ? (visibleFrame.minX + margin)
            : (visibleFrame.maxX - size.width - margin)

        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - size.height - margin)
        let preferredY = min(max(preferredCenterY - size.height / 2, minY), maxY)

        let primaryColumnFrames = existingFramesOnSameEdge.filter { rect in
            switch edge {
            case .left:
                return rect.minX <= baseX + 24
            case .right:
                return rect.maxX >= visibleFrame.maxX - margin - 24
            }
        }

        if let openY = bestNonOverlappingY(
            preferredY: preferredY,
            height: size.height,
            minY: minY,
            maxY: maxY,
            gap: gap,
            occupied: primaryColumnFrames
        ) {
            return NSRect(x: baseX, y: openY, width: size.width, height: size.height)
        }

        for column in 1...4 {
            let offset = CGFloat(column) * Constants.Shelf.cascadeStepX
            let candidateX: CGFloat
            if edge == .left {
                candidateX = min(baseX + offset, visibleFrame.maxX - size.width - margin)
            } else {
                candidateX = max(baseX - offset, visibleFrame.minX + margin)
            }
            let columnFrames = existingFramesOnSameEdge.filter { abs($0.origin.x - candidateX) < 16 }
            if let openY = bestNonOverlappingY(
                preferredY: preferredY,
                height: size.height,
                minY: minY,
                maxY: maxY,
                gap: gap,
                occupied: columnFrames
            ) {
                return NSRect(x: candidateX, y: openY, width: size.width, height: size.height)
            }
        }

        let stepOffset = CGFloat(existingFramesOnSameEdge.count % 5) * 24
        let fallbackY = min(max(preferredY - stepOffset, minY), maxY)
        return NSRect(x: baseX, y: fallbackY, width: size.width, height: size.height)
    }

    /// Snaps a user-dragged shelf deterministically to whichever horizontal half of the screen
    /// it was dragged into (past `visibleFrame.midX`), preserving its vertical Y position clamped
    /// inside `visibleFrame` while NEVER allowing it to land on top of another shelf's territory.
    /// When overlapping one or more neighboring shelves, snaps cleanly to the free space above
    /// or below the overlapped shelf/cluster depending on which side has more overlap.
    static func anchoredFrameAfterDrag(
        draggedFrame: NSRect,
        cursorPoint: NSPoint? = nil,
        visibleFrame: NSRect,
        existingFramesOnLeftEdge: [NSRect] = [],
        existingFramesOnRightEdge: [NSRect] = []
    ) -> (edge: ScreenEdge, frame: NSRect) {
        let margin = Constants.Shelf.edgeMargin
        let gap = Constants.Shelf.stackSpacing
        // Use the shelf's center X (which moves 1:1 with the drag) against the screen's horizontal halfway line.
        let referenceX = draggedFrame.midX
        let edge: ScreenEdge = referenceX < visibleFrame.midX ? .left : .right
        let baseX: CGFloat = (edge == .left)
            ? (visibleFrame.minX + margin)
            : (visibleFrame.maxX - draggedFrame.width - margin)
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - draggedFrame.height - margin)
        let desiredY = min(max(draggedFrame.origin.y, minY), maxY)

        let existingOnEdge = (edge == .left) ? existingFramesOnLeftEdge : existingFramesOnRightEdge
        let primaryColumnFrames = existingOnEdge.filter { rect in
            switch edge {
            case .left:
                return rect.minX <= baseX + 24
            case .right:
                return rect.maxX >= visibleFrame.maxX - margin - 24
            }
        }

        if let openY = resolveNonOverlappingY(
            desiredY: desiredY,
            height: draggedFrame.height,
            minY: minY,
            maxY: maxY,
            gap: gap,
            occupied: primaryColumnFrames
        ) {
            return (edge, NSRect(x: baseX, y: openY, width: draggedFrame.width, height: draggedFrame.height))
        }

        // If the primary edge column is completely packed vertically, cascade inward into
        // the first column that has non-overlapping vertical space.
        for column in 1...4 {
            let offset = CGFloat(column) * Constants.Shelf.cascadeStepX
            let candidateX: CGFloat
            if edge == .left {
                candidateX = min(baseX + offset, visibleFrame.maxX - draggedFrame.width - margin)
            } else {
                candidateX = max(baseX - offset, visibleFrame.minX + margin)
            }
            let columnFrames = existingOnEdge.filter { abs($0.origin.x - candidateX) < 16 }
            if let openY = resolveNonOverlappingY(
                desiredY: desiredY,
                height: draggedFrame.height,
                minY: minY,
                maxY: maxY,
                gap: gap,
                occupied: columnFrames
            ) {
                return (edge, NSRect(x: candidateX, y: openY, width: draggedFrame.width, height: draggedFrame.height))
            }
        }

        return (edge, NSRect(x: baseX, y: desiredY, width: draggedFrame.width, height: draggedFrame.height))
    }

    /// Resolves a non-overlapping vertical origin `y` inside `[minY, maxY]` for a shelf of `height`.
    /// Merges adjacent occupied shelves whose inter-shelf gap cannot fit `height` into contiguous
    /// territory clusters, and snaps above or below the overlapped shelf/cluster depending on which
    /// side has more vertical overlap (falling back to the opposite side if the preferred side is
    /// blocked by the screen boundary).
    static func resolveNonOverlappingY(
        desiredY: CGFloat,
        height: CGFloat,
        minY: CGFloat,
        maxY: CGFloat,
        gap: CGFloat,
        occupied: [NSRect]
    ) -> CGFloat? {
        guard maxY >= minY else { return nil }
        let clampedDesired = min(max(desiredY, minY), maxY)
        guard !occupied.isEmpty else { return clampedDesired }

        // 1. Sort existing shelves bottom-to-top and merge any neighbors that don't leave enough
        //    room between them to fit `height` with `gap` clearance on both sides.
        let sorted = occupied
            .map { (minY: $0.minY, maxY: $0.maxY) }
            .sorted { $0.minY < $1.minY }

        var clusters: [(minY: CGFloat, maxY: CGFloat)] = []
        let minClearGapBetweenClusters = height + 2 * gap
        for interval in sorted {
            if let last = clusters.last, interval.minY - last.maxY < minClearGapBetweenClusters {
                clusters[clusters.count - 1].maxY = max(last.maxY, interval.maxY)
            } else {
                clusters.append(interval)
            }
        }

        // 2. Collect all valid non-overlapping origin-Y intervals [low, high] within [minY, maxY].
        var freeRanges: [(low: CGFloat, high: CGFloat)] = []
        var cursor = minY
        for cluster in clusters {
            let slotHigh = min(maxY, cluster.minY - gap - height)
            if slotHigh >= cursor {
                freeRanges.append((low: cursor, high: slotHigh))
            }
            cursor = max(cursor, cluster.maxY + gap)
        }
        if maxY >= cursor {
            freeRanges.append((low: cursor, high: maxY))
        }

        guard !freeRanges.isEmpty else { return nil }

        // 3. If desiredY is already completely clear of every shelf's territory, keep it!
        if freeRanges.contains(where: { clampedDesired >= $0.low && clampedDesired <= $0.high }) {
            return clampedDesired
        }

        // 4. Identify the overlapped shelf/cluster (because adjacent clusters are separated by
        //    at least `height + 2 * gap`, a dragged shelf of `height` overlaps at most one cluster).
        let draggedBottom = clampedDesired
        let draggedTop = clampedDesired + height
        let draggedMid = clampedDesired + height / 2

        let overlappedCluster = clusters.first { cluster in
            draggedBottom < cluster.maxY + gap && draggedTop > cluster.minY - gap
        } ?? clusters.min(by: {
            abs(($0.minY + $0.maxY) / 2 - draggedMid) < abs(($1.minY + $1.maxY) / 2 - draggedMid)
        })!

        // 5. Snap above or below depending on which side of the shelf/cluster has more overlap.
        let clusterMid = (overlappedCluster.minY + overlappedCluster.maxY) / 2
        let upperOverlap = max(0, min(draggedTop, overlappedCluster.maxY) - max(draggedBottom, clusterMid))
        let lowerOverlap = max(0, min(draggedTop, clusterMid) - max(draggedBottom, overlappedCluster.minY))

        let preferAbove: Bool
        if abs(upperOverlap - lowerOverlap) > 0.5 {
            preferAbove = upperOverlap > lowerOverlap
        } else {
            preferAbove = draggedMid >= clusterMid
        }

        let targetAbove = overlappedCluster.maxY + gap
        let targetBelow = overlappedCluster.minY - gap - height

        let rangesAbove = freeRanges.filter { $0.high >= targetAbove - 0.5 }
        let rangesBelow = freeRanges.filter { $0.low <= targetBelow + 0.5 }

        func closestY(in ranges: [(low: CGFloat, high: CGFloat)], to target: CGFloat) -> CGFloat? {
            ranges
                .map { min(max(target, $0.low), $0.high) }
                .min(by: { abs($0 - target) < abs($1 - target) })
        }

        if preferAbove {
            if let y = closestY(in: rangesAbove, to: targetAbove) {
                return y
            }
            if let y = closestY(in: rangesBelow, to: targetBelow) {
                return y
            }
        } else {
            if let y = closestY(in: rangesBelow, to: targetBelow) {
                return y
            }
            if let y = closestY(in: rangesAbove, to: targetAbove) {
                return y
            }
        }

        return closestY(in: freeRanges, to: clampedDesired)
    }

    /// Computes the Auto-Hide collapsed frame strictly INSIDE `screenFrame` (never extending
    /// past `screenFrame.minX` or `screenFrame.maxX`), so nothing bleeds into adjacent
    /// macOS Virtual Desktops (Spaces) or neighboring monitors!
    static func autoHideFrame(
        from expandedFrame: NSRect,
        edge: ScreenEdge,
        screenFrame: NSRect,
        visibleWidth: CGFloat
    ) -> NSRect {
        let clampedWidth = min(max(20, visibleWidth), expandedFrame.width)
        let x: CGFloat
        switch edge {
        case .left:
            x = screenFrame.minX
        case .right:
            x = screenFrame.maxX - clampedWidth
        }
        return NSRect(x: x, y: expandedFrame.origin.y, width: clampedWidth, height: expandedFrame.height)
    }

    private static func bestNonOverlappingY(
        preferredY: CGFloat,
        height: CGFloat,
        minY: CGFloat,
        maxY: CGFloat,
        gap: CGFloat,
        occupied: [NSRect]
    ) -> CGFloat? {
        func overlapsAny(_ y: CGFloat) -> Bool {
            let top = y + height
            for rect in occupied {
                if y < rect.maxY + gap && top > rect.minY - gap {
                    return true
                }
            }
            return false
        }

        if !overlapsAny(preferredY) {
            return preferredY
        }

        var candidates: [CGFloat] = [maxY, minY]
        for rect in occupied {
            candidates.append(rect.minY - gap - height)
            candidates.append(rect.maxY + gap)
        }

        let valid = candidates
            .map { min(max($0, minY), maxY) }
            .filter { !overlapsAny($0) }

        return valid.min(by: { abs($0 - preferredY) < abs($1 - preferredY) })
    }
}

enum ScreenGeometry {
    static func screen(containing point: NSPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return exact
        }
        return NSScreen.screens.min(by: {
            distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame)
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func hasAdjacentScreen(to screen: NSScreen, on edge: ScreenEdge) -> Bool {
        let frame = screen.frame
        let tolerance: CGFloat = 4.0
        for other in NSScreen.screens where other != screen {
            let verticalOverlap = min(frame.maxY, other.frame.maxY) - max(frame.minY, other.frame.minY)
            guard verticalOverlap > 10 else { continue }
            switch edge {
            case .left:
                if abs(other.frame.maxX - frame.minX) <= tolerance {
                    return true
                }
            case .right:
                if abs(other.frame.minX - frame.maxX) <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}
