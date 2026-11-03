import Foundation

struct SearchKey {
    let name: String
    let aliases: [String]
    let pinyin: String
    let initials: String

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    init(name: String, aliases: [String] = []) {
        self.name = Self.normalize(name)
        self.aliases = aliases.map(Self.normalize)
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? name
        let words = Self.normalize(latin).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        pinyin = words.joined()
        initials = words.compactMap(\.first).map(String.init).joined()
    }
    func score(_ query: String) -> Int? {
        let q = Self.normalize(query)
        if q.isEmpty { return 0 }
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if name.contains(q) { return 2 }
        if aliases.contains(where: { $0.contains(q) }) { return 3 }
        let compact = q.filter { !$0.isWhitespace }
        if !compact.isEmpty && pinyin.contains(compact) { return 4 }
        if !compact.isEmpty && initials.contains(compact) { return 5 }
        return nil
    }
}

struct ApplicationRecord {
    let url: URL
    let name: String
    let bundleID: String
    let key: SearchKey
}

enum Catalog {
    static func scan() -> [ApplicationRecord] {
        let fm = FileManager.default
        let roots = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications"]
        var seen = Set<String>()
        var records: [ApplicationRecord] = []
        for path in roots {
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                if url.pathExtension.lowercased() == "app" {
                    walker.skipDescendants()
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                    guard seen.insert(canonical.path).inserted, let bundle = Bundle(url: canonical) else { continue }
                    let info = bundle.infoDictionary ?? [:]
                    let bundleID = bundle.bundleIdentifier ?? canonical.path
                    if bundleID == "local.launchdeck.app" { continue }
                    if (info["LSBackgroundOnly"] as? Bool) == true { continue }
                    guard bundle.executableURL != nil else { continue }
                    let local = bundle.localizedInfoDictionary ?? [:]
                    let fallback = canonical.deletingPathExtension().lastPathComponent
                    let name = (local["CFBundleDisplayName"] as? String) ?? (local["CFBundleName"] as? String) ?? (info["CFBundleDisplayName"] as? String) ?? fallback
                    let aliases = [fallback, info["CFBundleName"] as? String ?? "", info["CFBundleExecutable"] as? String ?? "", bundleID]
                    records.append(ApplicationRecord(url: canonical, name: name, bundleID: bundleID, key: SearchKey(name: name, aliases: aliases)))
                } else if url.pathExtension == "bundle" || url.pathExtension == "framework" || url.pathExtension == "appex" {
                    walker.skipDescendants()
                }
            }
        }
        return records.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }
    static func search(_ records: [ApplicationRecord], query: String) -> [ApplicationRecord] {
        if SearchKey.normalize(query).isEmpty { return records }
        return records.enumerated().compactMap { index, app -> (Int, Int, ApplicationRecord)? in
            guard let score = app.key.score(query) else { return nil }
            return (score, index, app)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
    }
}

struct AppFolder: Codable {
    var id: String
    var name: String
    var paths: [String]
    var key: String { "/LaunchDeckFolders/" + id }
}

struct Preferences: Codable {
    var folders: [AppFolder]?
    func folder(for key: String) -> AppFolder? { (folders ?? []).first { $0.key == key } }
    func groupedApplications(_ apps: [ApplicationRecord], inside key: String? = nil) -> [ApplicationRecord] {
        let visible = visibleApplications(apps)
        let byPath = Dictionary(uniqueKeysWithValues: visible.map { ($0.url.path, $0) })
        if let key, let folder = folder(for: key) { return folder.paths.compactMap { byPath[$0] } }
        var grouped = Set<String>(), result: [ApplicationRecord] = []
        for folder in folders ?? [] {
            let members = folder.paths.filter { byPath[$0] != nil && !grouped.contains($0) }
            guard !members.isEmpty else { continue }
            grouped.formUnion(members)
            result.append(ApplicationRecord(url: URL(fileURLWithPath: folder.key), name: folder.name, bundleID: folder.id, key: SearchKey(name: folder.name)))
        }
        result += visible.filter { !grouped.contains($0.url.path) }
        let rank = Dictionary((selectedApplicationOrder ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return result.enumerated().sorted {
            let a = rank[$0.element.url.path] ?? Int.max, b = rank[$1.element.url.path] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map { $0.element }
    }
    mutating func group(_ source: String, onto target: String, rootOrder: [String]) {
        guard source != target, folder(for: source) == nil else { return }
        var groups = folders ?? []
        for i in groups.indices { groups[i].paths.removeAll { $0 == source } }
        let destination: String
        if let i = groups.firstIndex(where: { $0.key == target }) {
            if !groups[i].paths.contains(source) { groups[i].paths.append(source) }
            destination = target
        } else {
            for i in groups.indices { groups[i].paths.removeAll { $0 == target } }
            let folder = AppFolder(id: UUID().uuidString, name: "新建文件夹", paths: [target, source])
            groups.append(folder); destination = folder.key
        }
        folders = groups.filter { !$0.paths.isEmpty }
        var order = rootOrder.filter { $0 != source }
        if let index = order.firstIndex(of: target) { order[index] = destination }
        else if !order.contains(destination) { order.append(destination) }
        selectedApplicationOrder = order
    }
    mutating func saveOrder(_ order: [String], inside key: String?) {
        if let key, let i = folders?.firstIndex(where: { $0.key == key }) {
            let hidden = folders![i].paths.filter { !order.contains($0) }
            folders![i].paths = order + hidden
        } else {
            selectedApplicationOrder = order + (selectedApplicationOrder ?? []).filter { !order.contains($0) }
        }
    }
    mutating func dissolveFolder(_ key: String) {
        guard let folder = folder(for: key) else { return }
        var order = (selectedApplicationOrder ?? []).filter { !folder.paths.contains($0) }
        let index = order.firstIndex(of: key) ?? order.endIndex
        order.removeAll { $0 == key }
        order.insert(contentsOf: folder.paths, at: min(index, order.count))
        selectedApplicationOrder = order
        folders?.removeAll { $0.key == key }
    }
    mutating func removeFromFolder(_ path: String, key: String) {
        guard let i = folders?.firstIndex(where: { $0.key == key }) else { return }
        folders![i].paths.removeAll { $0 == path }
        folders = folders?.filter { !$0.paths.isEmpty }
        if !(selectedApplicationOrder ?? []).contains(path) { selectedApplicationOrder = (selectedApplicationOrder ?? []) + [path] }
    }

    // Optional fields preserve preferences saved by older versions.
    var onlySelectedApplications: Bool?
    var selectedApplicationPaths: Set<String>?
    var selectedApplicationOrder: [String]?
    // A cumulative inventory distinguishes new installs from intentionally unchecked apps.
    var knownApplicationPaths: Set<String>?
    @discardableResult mutating func includeNewApplications(_ apps: [ApplicationRecord]) -> Bool {
        guard !apps.isEmpty else { return false }
        let current = Set(apps.map { $0.url.path })
        guard let known = knownApplicationPaths else {
            // On upgrade, establish a baseline without selecting existing hidden apps.
            knownApplicationPaths = current.union(selectedApplicationPaths ?? [])
            return true
        }
        let newPaths = current.subtracting(known)
        guard !newPaths.isEmpty else { return false }
        let additions = apps.map { $0.url.path }.filter { newPaths.contains($0) }
        let existing = groupedApplications(apps.filter { !newPaths.contains($0.url.path) }).map { $0.url.path }
        let existingSet = Set(existing)
        let retained = (selectedApplicationOrder ?? []).filter { !existingSet.contains($0) && !newPaths.contains($0) }
        selectedApplicationOrder = existing + retained + additions
        selectedApplicationPaths = (selectedApplicationPaths ?? []).union(newPaths)
        knownApplicationPaths = known.union(current)
        return true
    }

    func visibleApplications(_ apps: [ApplicationRecord]) -> [ApplicationRecord] {
        guard onlySelectedApplications == true else { return apps }
        let selected = selectedApplicationPaths ?? []
        let ranks = Dictionary((selectedApplicationOrder ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return apps.enumerated().filter { selected.contains($0.element.url.path) }.sorted {
            let a = ranks[$0.element.url.path] ?? Int.max, b = ranks[$1.element.url.path] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map { $0.element }
    }
    mutating func moveSelected(_ path: String, to target: String, apps: [ApplicationRecord]) {
        var order = visibleApplications(apps).map { $0.url.path }
        guard let source = order.firstIndex(of: path), let destination = order.firstIndex(of: target), source != destination else { return }
        order.remove(at: source); order.insert(path, at: destination)
        selectedApplicationOrder = order
    }
    var enabled = true
    var showDock = true
    var rows = 5
    var columns = 7
    var sensitivity = 0.55
    var corner = 0
    var keyCode: UInt32 = 49
    var modifiers: UInt32 = 2048 // Carbon optionKey
    var shortcutName = "⌥ Space"
    mutating func validate() {
        rows = min(8, max(2, rows)); columns = min(12, max(3, columns))
        sensitivity = sensitivity.isFinite ? min(1, max(0, sensitivity)) : 0.55
        corner = min(4, max(0, corner))
        keyCode = min(127, keyCode)
        modifiers &= 0x1F00
    }
    static var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchDeck/preferences.json")
    }
    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: location), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Preferences() }
        value.validate(); return value
    }
    func save() throws {
        let location = Self.location
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: location, options: .atomic)
    }
}

enum LayoutMath {
    static func folderHoverRect(_ slot: CGRect) -> CGRect {
        let size = max(24, min(88, slot.width - 28, slot.height - 43))
        return CGRect(x: slot.midX - size / 2, y: slot.minY + (slot.height - size + 22) / 2, width: size, height: size).insetBy(dx: -14, dy: -14)
    }
    static func pageCount(items: Int, capacity: Int) -> Int { max(1, (items + max(1, capacity) - 1) / max(1, capacity)) }
    static func clampedPage(_ page: Int, items: Int, capacity: Int) -> Int { min(max(0, page), pageCount(items: items, capacity: capacity) - 1) }
}

func runTests() {
    let hoverSlot = CGRect(x: 100, y: 200, width: 170, height: 145)
    let hoverRect = LayoutMath.folderHoverRect(hoverSlot)
    precondition(hoverRect.contains(CGPoint(x: 185 - 43, y: 283.5)))
    precondition(hoverRect.contains(CGPoint(x: 185 + 43, y: 283.5)))
    precondition(!hoverRect.contains(CGPoint(x: 110, y: 210)))
    print("PASS: hover covers icon edges while leaving insertion gaps")
    let calculator = SearchKey(name: "计算器", aliases: ["Calculator"])
    let monitor = SearchKey(name: "活动监视器")
    precondition(calculator.score("计算") != nil)
    precondition(calculator.score("jisuan") != nil)
    precondition(calculator.score("jsq") != nil)
    precondition(monitor.score("jsq") != nil)
    precondition(calculator.score("CALCULATOR") != nil)
    precondition(calculator.score("zzzznomatch938") == nil)
    precondition(SearchKey(name: "Google Chrome").score("CHROME") == SearchKey(name: "Google Chrome").score("chrome"))
    precondition(LayoutMath.pageCount(items: 0, capacity: 35) == 1)
    precondition(LayoutMath.pageCount(items: 35, capacity: 35) == 1)
    precondition(LayoutMath.pageCount(items: 36, capacity: 35) == 2)
    precondition(LayoutMath.clampedPage(9, items: 119, capacity: 35) == 3)
    for rows in 2...8 { for columns in 3...12 {
        let n = 119, capacity = rows * columns
        let flattened = (0..<LayoutMath.pageCount(items: n, capacity: capacity)).flatMap { page in Array((page * capacity)..<min(n, (page + 1) * capacity)) }
        precondition(flattened == Array(0..<n))
    } }
    var bad = Preferences(); bad.rows = 99; bad.columns = -1; bad.corner = 8; bad.sensitivity = .infinity; bad.validate()
    precondition(bad.rows == 8 && bad.columns == 3 && bad.corner == 4 && bad.sensitivity == 0.55)
    let roundTrip = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(Preferences()))
    precondition(roundTrip.rows == 5 && roundTrip.columns == 7)
    let sample = [ApplicationRecord(url: URL(fileURLWithPath: "/A.app"), name: "Alpha", bundleID: "a", key: SearchKey(name: "Alpha")),
                  ApplicationRecord(url: URL(fileURLWithPath: "/B.app"), name: "Beta", bundleID: "b", key: SearchKey(name: "Beta"))]
    var visibility = Preferences()
    precondition(visibility.visibleApplications(sample).count == 2)
    visibility.onlySelectedApplications = true
    precondition(visibility.visibleApplications(sample).isEmpty)
    visibility.selectedApplicationPaths = ["/B.app", "/Missing.app"]
    precondition(visibility.visibleApplications(sample).map(\.name) == ["Beta"])
    precondition(Catalog.search(visibility.visibleApplications(sample), query: "Alpha").isEmpty)
    let restored = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(visibility))
    precondition(restored.onlySelectedApplications == true && restored.selectedApplicationPaths == visibility.selectedApplicationPaths)
    visibility.onlySelectedApplications = false
    precondition(visibility.visibleApplications(sample).count == 2 && visibility.selectedApplicationPaths!.contains("/B.app"))
    var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(visibility)) as! [String: Any]
    legacy.removeValue(forKey: "onlySelectedApplications"); legacy.removeValue(forKey: "selectedApplicationPaths")
    legacy["rows"] = 6
    let migrated = try! JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
    precondition(migrated.rows == 6 && migrated.visibleApplications(sample).count == 2)
    visibility.onlySelectedApplications = true
    visibility.selectedApplicationPaths = ["/A.app", "/B.app"]
    visibility.moveSelected("/B.app", to: "/A.app", apps: sample)
    precondition(visibility.visibleApplications(sample).map(\.name) == ["Beta", "Alpha"])
    let ordered = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(visibility))
    precondition(ordered.visibleApplications(sample).map(\.name) == ["Beta", "Alpha"])
    var automatic = Preferences()
    automatic.onlySelectedApplications = true
    automatic.selectedApplicationPaths = ["/B.app"]
    precondition(!automatic.includeNewApplications([]))
    precondition(automatic.knownApplicationPaths == nil)
    precondition(automatic.includeNewApplications(sample))
    precondition(automatic.selectedApplicationPaths == ["/B.app"])
    let added = ApplicationRecord(url: URL(fileURLWithPath: "/C.app"), name: "Charlie", bundleID: "c", key: SearchKey(name: "Charlie"))
    let expanded = sample + [added]
    precondition(automatic.includeNewApplications(expanded))
    precondition(automatic.visibleApplications(expanded).map(\.name) == ["Beta", "Charlie"])
    automatic.selectedApplicationPaths!.remove("/C.app")
    precondition(!automatic.includeNewApplications(sample))
    automatic = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(automatic))
    precondition(!automatic.includeNewApplications(expanded))
    precondition(!automatic.selectedApplicationPaths!.contains("/C.app") && !automatic.selectedApplicationPaths!.contains("/A.app"))
    let offline = ApplicationRecord(url: URL(fileURLWithPath: "/D.app"), name: "Delta", bundleID: "d", key: SearchKey(name: "Delta"))
    precondition(automatic.includeNewApplications(expanded + [offline]))
    precondition(automatic.visibleApplications(expanded + [offline]).map(\.name) == ["Beta", "Delta"])
    var allMode = Preferences()
    allMode.includeNewApplications(sample)
    allMode.includeNewApplications(expanded)
    precondition(allMode.selectedApplicationPaths == ["/C.app"])
    print("PASS: new-install selection, upgrade baseline, restart/offline installs, deselection, reinstall, order, all-app mode")
    var groups = visibility
    groups.group("/B.app", onto: "/A.app", rootOrder: ["/A.app", "/B.app"])
    let groupKey = groups.folders!.first!.key
    precondition(groups.groupedApplications(sample).count == 1)
    precondition(groups.groupedApplications(sample, inside: groupKey).map(\.name) == ["Alpha", "Beta"])
    groups.saveOrder(["/B.app", "/A.app"], inside: groupKey)
    var dissolved = groups
    dissolved.dissolveFolder(groupKey)
    precondition(dissolved.groupedApplications(sample).map(\.name) == ["Beta", "Alpha"])
    let restoredGroups = try! JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(groups))
    precondition(restoredGroups.groupedApplications(sample, inside: groupKey).map(\.name) == ["Beta", "Alpha"])
    groups.removeFromFolder("/B.app", key: groupKey)
    precondition(groups.groupedApplications(sample).count == 2)
    groups.removeFromFolder("/A.app", key: groupKey)
    precondition(groups.folders!.isEmpty)
    print("PASS: folder creation, inner ordering, persistence, move out, empty folder cleanup")
    print("PASS: selected drag order and restart serialization")
    print("PASS: app visibility, empty selection, hidden-app search, persistence, legacy migration")
    print("PASS: search, pinyin, initials, normalization, empty results, all 70 grid combinations, bounds, configuration serialization")
}
