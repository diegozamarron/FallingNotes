import SwiftUI

/// A named set of instruments that can be changed together. An instrument belongs to at most one group.
struct PartGroup: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var members: [Int]          // indices into AppModel.parts
    var collapsed = false
}

/// A rough instrument family, used to suggest group names and to auto-group.
enum Family: String, CaseIterable {
    case keys = "Keys", strings = "Strings", woodwinds = "Woodwinds", brass = "Brass"
    case guitars = "Guitars & Bass", voices = "Voices", synths = "Synths"
    case percussion = "Percussion", other = "Other"

    static func of(program: Int, isDrums: Bool) -> Family {
        if isDrums { return .percussion }
        switch program {
        case 0...8, 16...23: return .keys
        case 9...15, 47, 112...119: return .percussion
        case 24...39: return .guitars
        case 40...46, 48...51: return .strings
        case 52...54: return .voices
        case 55...63: return .brass
        case 64...79: return .woodwinds
        case 80...103: return .synths
        default: return .other
        }
    }
}

extension AppModel {
    // MARK: Selection

    func isSelected(_ i: Int) -> Bool { selection.contains(i) }

    func toggleSelected(_ i: Int) {
        if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
    }

    func selectAll() { selection = Set(parts.indices) }
    func clearSelection() { selection = [] }

    /// Selects every member of a group, or clears them if they were all already selected.
    func toggleSelection(of group: PartGroup) {
        let all = Set(group.members)
        if all.isSubset(of: selection) { selection.subtract(all) } else { selection.formUnion(all) }
    }

    var selectedIndices: [Int] { selection.sorted() }

    // MARK: Groups

    func groupIndex(containing part: Int) -> Int? { groups.firstIndex { $0.members.contains(part) } }

    var ungroupedParts: [Int] { parts.indices.filter { groupIndex(containing: $0) == nil } }

    func familyOf(_ i: Int) -> Family {
        guard let song, song.parts.indices.contains(i), parts.indices.contains(i) else { return .other }
        return .of(program: parts[i].program, isDrums: song.parts[i].isDrums)
    }

    /// A name for a new group: the shared family if there is one ("Strings"), otherwise "Group N".
    func suggestedGroupName(for indices: [Int]) -> String {
        let families = Set(indices.map(familyOf))
        if families.count == 1, let f = families.first, f != .other,
           !groups.contains(where: { $0.name == f.rawValue }) { return f.rawValue }
        var n = groups.count + 1
        while groups.contains(where: { $0.name == "Group \(n)" }) { n += 1 }
        return "Group \(n)"
    }

    /// Puts the given instruments into a new group (taking them out of any group they were in).
    @discardableResult
    func createGroup(from indices: [Int], name: String? = nil) -> UUID? {
        let valid = indices.filter { parts.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return nil }
        let groupName = name ?? suggestedGroupName(for: valid)
        removeFromGroups(valid)
        let group = PartGroup(name: groupName, members: valid)
        groups.append(group)
        return group.id
    }

    func removeFromGroups(_ indices: [Int]) {
        let drop = Set(indices)
        for g in groups.indices { groups[g].members.removeAll { drop.contains($0) } }
        groups.removeAll { $0.members.isEmpty }
    }

    func ungroup(_ id: UUID) { groups.removeAll { $0.id == id } }

    func renameGroup(_ id: UUID, to name: String) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].name = name
    }

    func toggleCollapsed(_ id: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].collapsed.toggle()
    }

    /// One group per instrument family that has two or more instruments in this song.
    func autoGroup() {
        var byFamily: [Family: [Int]] = [:]
        for i in parts.indices { byFamily[familyOf(i), default: []].append(i) }
        groups = []
        for family in Family.allCases {
            if let members = byFamily[family], members.count >= 2 {
                groups.append(PartGroup(name: family.rawValue, members: members))
            }
        }
    }

    // MARK: Changing several instruments at once

    func setLook(_ indices: [Int], _ look: PartLook) { indices.forEach { setLook($0, look) } }

    func setAudible(_ indices: [Int], _ on: Bool) { indices.forEach { setAudible($0, on) } }

    func setColor(_ indices: [Int], _ color: Color) {
        for i in indices where parts.indices.contains(i) { parts[i].color = color }
    }

    /// Drums keep their kit.
    func setProgram(_ indices: [Int], _ program: Int) {
        guard let song else { return }
        for i in indices where song.parts.indices.contains(i) && !song.parts[i].isDrums { setProgram(i, program) }
    }

    /// Moves the group's average volume to `target` while keeping the balance between its members:
    /// every member is scaled by the same factor (so a loud violin stays louder than a quiet viola).
    func scaleVolumes(_ indices: [Int], toAverage target: Double) {
        let valid = indices.filter { parts.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let current = averageVolume(valid)
        let goal = min(max(target, 0), 1.5)
        for i in valid {
            if current > 0.001 {
                setVolume(i, min(max(parts[i].volume * goal / current, 0), 1.5))
            } else {
                setVolume(i, goal)     // everything was silent: nothing to scale, so set them all
            }
        }
    }

    // MARK: What the members have in common (nil = they differ), for showing group state

    func commonLook(_ indices: [Int]) -> PartLook? {
        let looks = indices.compactMap { parts.indices.contains($0) ? parts[$0].look : nil }
        guard let first = looks.first, looks.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    func commonAudible(_ indices: [Int]) -> Bool? {
        let values = indices.compactMap { parts.indices.contains($0) ? parts[$0].audible : nil }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    func averageVolume(_ indices: [Int]) -> Double {
        let values = indices.compactMap { parts.indices.contains($0) ? parts[$0].volume : nil }
        return values.isEmpty ? 1 : values.reduce(0, +) / Double(values.count)
    }

    func commonColor(_ indices: [Int]) -> Color? {
        let colors = indices.compactMap { parts.indices.contains($0) ? parts[$0].color : nil }
        guard let first = colors.first, colors.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    func commonProgram(_ indices: [Int]) -> Int? {
        guard let song else { return nil }
        let values = indices.filter { song.parts.indices.contains($0) && !song.parts[$0].isDrums }.map { parts[$0].program }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
