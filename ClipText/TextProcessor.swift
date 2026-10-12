//
//  TextProcessor.swift
//  ClipText
//
//  Adapted from TextGrab (https://github.com/arsh342/TextGrab)
//  Copyright (c) 2026 arsh342. MIT License.
//

import CoreGraphics
import Foundation

protocol TextProcessor: Sendable {
    func process(observations: [OCRObservation], mode: OCRMode) -> String
}

final class DefaultTextProcessor: TextProcessor {
    private let lineGroupingTolerance: CGFloat = 0.5

    func process(observations: [OCRObservation], mode: OCRMode = .normal) -> String {
        guard !observations.isEmpty else { return "" }

        let lines = groupIntoLines(observations)
        // Vision uses a bottom-left origin, so larger Y values are visually higher.
        let sortedLines = lines.sorted { $0.minY > $1.minY }

        if mode == .code {
            return formatCode(sortedLines)
        }

        if mode == .table {
            return formatTable(sortedLines)
        }

        let linesText = sortedLines.map { line in
            let sortedWords = line.observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            return sortedWords.map { $0.text }.joined(separator: " ")
        }

        return linesText.joined(separator: "\n")
    }

    /// Rebuilds leading indentation that OCR discards, from each line's
    /// horizontal offset relative to the left-most line and an estimated
    /// per-character width for that line.
    private func formatCode(_ lines: [TextLine]) -> String {
        guard let baseMinX = lines.map({ $0.minX }).min() else { return "" }

        return lines.map { line -> String in
            let charWidth = codeCharacterWidth(for: line)
            let indentSpaces = charWidth > 0
                ? min(16, max(0, Int(((line.minX - baseMinX) / charWidth).rounded())))
                : 0
            let sortedWords = line.observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let text = sortedWords.map { $0.text }.joined(separator: " ")
            return String(repeating: " ", count: indentSpaces) + text
        }
        .joined(separator: "\n")
    }

    private func codeCharacterWidth(for line: TextLine) -> CGFloat {
        let widths = line.observations.compactMap { observation -> CGFloat? in
            guard !observation.text.isEmpty else { return nil }
            return observation.boundingBox.width / CGFloat(observation.text.count)
        }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) / CGFloat(widths.count)
    }

    private func formatTable(_ lines: [TextLine]) -> String {
        let rowsWithGeometry = lines.map { line in
            let cells = line.observations
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .flatMap { observation -> [(text: String, minX: CGFloat, maxX: CGFloat)] in
                    let value = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    var cellTexts: [String] = []

                    func parsePipeSeparated(_ value: String) -> [String] {
                        var cells: [String] = []
                        var currentCell = ""
                        var i = 0
                        let chars = Array(value)

                        while i < chars.count {
                            let char = chars[i]
                            if char == "|" {
                                if i > 0 && chars[i - 1] == "\\" {
                                    currentCell = String(currentCell.dropLast()) + "|"
                                } else {
                                    cells.append(currentCell.trimmingCharacters(in: .whitespacesAndNewlines))
                                    currentCell = ""
                                }
                            } else {
                                currentCell.append(char)
                            }
                            i += 1
                        }

                        cells.append(currentCell.trimmingCharacters(in: .whitespacesAndNewlines))
                        if cells.first?.isEmpty == true { cells.removeFirst() }
                        if cells.last?.isEmpty == true { cells.removeLast() }
                        return cells
                    }

                    if value.contains("|") {
                        cellTexts = parsePipeSeparated(value)
                    } else if value.contains("\t") {
                        cellTexts = value.split(separator: "\t", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } else if value.contains("  ") {
                        let cells = value.components(separatedBy: "  ")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        if cells.count > 1 {
                            cellTexts = cells
                        } else {
                            cellTexts = [value]
                        }
                    } else {
                        cellTexts = [value]
                    }

                    let obsMinX = observation.boundingBox.minX
                    let obsMaxX = observation.boundingBox.maxX
                    let obsWidth = obsMaxX - obsMinX
                    return cellTexts.enumerated().map { index, text in
                        let cellWidth = obsWidth / CGFloat(max(1, cellTexts.count))
                        let cellMinX = obsMinX + CGFloat(index) * cellWidth
                        let cellMaxX = cellMinX + cellWidth
                        return (text: text, minX: cellMinX, maxX: cellMaxX)
                    }
                }
            return cells
        }

        guard !rowsWithGeometry.isEmpty else { return "" }

        let hasTableStructure = rowsWithGeometry.contains { $0.count > 1 }
        guard hasTableStructure else {
            return rowsWithGeometry.map { $0.first?.text ?? "" }.joined(separator: "\n")
        }

        let dataRows = rowsWithGeometry.filter { !isSeparatorRow($0.map(\.text)) }
        guard let firstRow = dataRows.first else { return "" }
        let columnCount = dataRows.map(\.count).max() ?? firstRow.count

        var columnBounds: [(minX: CGFloat, maxX: CGFloat)] = []
        if columnCount > 0 {
            columnBounds = firstRow.map { ($0.minX, $0.maxX) }

            for row in dataRows.dropFirst() {
                for (index, cell) in row.enumerated() where index < columnCount {
                    if index < columnBounds.count {
                        columnBounds[index].minX = min(columnBounds[index].minX, cell.minX)
                        columnBounds[index].maxX = max(columnBounds[index].maxX, cell.maxX)
                    } else {
                        columnBounds.append((cell.minX, cell.maxX))
                    }
                }
            }
        }

        var mergedRows: [[(text: String, minX: CGFloat, maxX: CGFloat)]] = []
        var mergedLines: [TextLine] = []

        for (rowIndex, row) in dataRows.enumerated() {
            let originalLine = lines[rowIndex]
            let paddedRow = row + Array(repeating: (text: "", minX: 0, maxX: 0), count: max(0, columnCount - row.count))
            let nonEmptyCells = paddedRow.enumerated().filter { !$0.element.text.isEmpty }

            if nonEmptyCells.count == 1, !mergedRows.isEmpty {
                let (cellIndex, cell) = nonEmptyCells[0]
                let targetColumnIndex = cellIndex < columnCount ? cellIndex : (columnCount - 1)

                let overlapsColumn = targetColumnIndex < columnBounds.count &&
                    cell.maxX >= columnBounds[targetColumnIndex].minX &&
                    cell.minX <= columnBounds[targetColumnIndex].maxX

                let prevLine = mergedLines[mergedRows.count - 1]
                let verticalProximity = abs(originalLine.centerY - prevLine.centerY) < (originalLine.maxY - originalLine.minY) * 1.5

                let prevRow = mergedRows[mergedRows.count - 1]
                let prevLastCellIndex = prevRow.lastIndex(where: { !$0.text.isEmpty }) ?? (columnCount - 1)
                let prevLastCell = prevRow[prevLastCellIndex]
                let isHyphenContinuation = prevLastCell.text.hasSuffix("-")

                let isLastColumnWrap = targetColumnIndex == columnCount - 1 && overlapsColumn && verticalProximity

                if isHyphenContinuation || isLastColumnWrap {
                    let value = cell.text
                    let mergeTargetIndex = isHyphenContinuation ? prevLastCellIndex : targetColumnIndex
                    if isHyphenContinuation {
                        mergedRows[mergedRows.count - 1][mergeTargetIndex].text += value
                    } else {
                        mergedRows[mergedRows.count - 1][mergeTargetIndex].text += " " + value
                    }
                } else {
                    mergedRows.append(paddedRow)
                    mergedLines.append(originalLine)
                }
            } else {
                mergedRows.append(paddedRow)
                mergedLines.append(originalLine)
            }
        }

        let normalizedRows = mergedRows.map { $0.map(\.text) }
        let widths = (0..<columnCount).map { index in
            normalizedRows.map { $0[index].count }.max() ?? 1
        }

        func render(_ row: [String]) -> String {
            let cells = row.enumerated().map { index, value in
                let escaped = value.replacingOccurrences(of: "|", with: "\\|")
                return escaped.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }

        let separator = "| " + widths.map { String(repeating: "-", count: max(3, $0)) }.joined(separator: " | ") + " |"
        return ([render(normalizedRows[0]), separator] + normalizedRows.dropFirst().map(render)).joined(separator: "\n")
    }

    private func isSeparatorRow(_ row: [String]) -> Bool {
        !row.isEmpty && row.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private func groupIntoLines(_ observations: [OCRObservation]) -> [TextLine] {
        var lines: [TextLine] = []

        for observation in observations.sorted(by: { $0.boundingBox.minY > $1.boundingBox.minY }) {
            let observationCenterY = observation.boundingBox.midY
            let observationHeight = observation.boundingBox.height
            let tolerance = observationHeight * lineGroupingTolerance

            if let lineIndex = lines.firstIndex(where: { line in
                abs(line.centerY - observationCenterY) <= tolerance
            }) {
                lines[lineIndex].observations.append(observation)
                lines[lineIndex].updateBounds()
            } else {
                lines.append(TextLine(observations: [observation]))
            }
        }

        return lines
    }
}

private struct TextLine {
    var observations: [OCRObservation]
    var minY: CGFloat
    var maxY: CGFloat
    var centerY: CGFloat
    var minX: CGFloat
    var maxX: CGFloat

    init(observations: [OCRObservation]) {
        self.observations = observations
        minY = observations.map { $0.boundingBox.minY }.min() ?? 0
        maxY = observations.map { $0.boundingBox.maxY }.max() ?? 0
        centerY = (minY + maxY) / 2
        minX = observations.map { $0.boundingBox.minX }.min() ?? 0
        maxX = observations.map { $0.boundingBox.maxX }.max() ?? 0
    }

    mutating func updateBounds() {
        guard !observations.isEmpty else { return }
        minY = observations.map { $0.boundingBox.minY }.min() ?? 0
        maxY = observations.map { $0.boundingBox.maxY }.max() ?? 0
        centerY = (minY + maxY) / 2
        minX = observations.map { $0.boundingBox.minX }.min() ?? 0
        maxX = observations.map { $0.boundingBox.maxX }.max() ?? 0
    }
}

final class CodeTextProcessor: TextProcessor {
    private let defaultProcessor = DefaultTextProcessor()

    func process(observations: [OCRObservation], mode: OCRMode = .code) -> String {
        let text = defaultProcessor.process(observations: observations, mode: .code)
        return Self.removingMarkdownFences(Self.joiningTrailingPunctuation(text))
    }

    static func joiningTrailingPunctuation(_ text: String) -> String {
        let attachBackwards: Set<Character> = [",", ";", ".", ":"]
        return text.components(separatedBy: .newlines).map { line -> String in
            var result = ""
            let chars = Array(line)
            var i = 0

            var inSingleQuoteString = false
            var inDoubleQuoteString = false
            var escapeNext = false

            while i < chars.count {
                let char = chars[i]

                if escapeNext {
                    escapeNext = false
                } else if char == "\\" && (inSingleQuoteString || inDoubleQuoteString) {
                    escapeNext = true
                } else if char == "'" && !inDoubleQuoteString && !escapeNext {
                    inSingleQuoteString.toggle()
                } else if char == "\"" && !inSingleQuoteString && !escapeNext {
                    inDoubleQuoteString.toggle()
                }

                if attachBackwards.contains(char) {
                    var j = result.count - 1
                    var whitespaceCount = 0
                    while j >= 0, result[result.index(result.startIndex, offsetBy: j)].isWhitespace {
                        whitespaceCount += 1
                        j -= 1
                    }

                    let inStringLiteral = inSingleQuoteString || inDoubleQuoteString
                    let nextChar = (i + 1 < chars.count) ? chars[i + 1] : nil
                    let isIsolated = nextChar == nil || nextChar!.isWhitespace

                    if isIsolated && whitespaceCount > 0 && !inStringLiteral {
                        result = String(result.dropLast(whitespaceCount))
                    }
                }

                result.append(char)
                i += 1
            }

            return result
        }.joined(separator: "\n")
    }

    static func removingMarkdownFences(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("```") else { return text }

        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
