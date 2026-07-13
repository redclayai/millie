import Foundation

/// A named, collapsible group of tabs in the sidebar (Arc/SigmaOS-style folder).
/// Membership is stored as tab IDs; the store resolves them against live tabs so
/// a closed tab simply drops out of the folder.
struct TabFolder: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var symbol: String      // SF Symbol shown next to the name.
    var isExpanded: Bool
    var tabIDs: [UUID]
    /// A group produced by "Tidy Tabs" (auto-grouped by site), as opposed to a
    /// permanent user-made folder. Rendered in its own section below the folders
    /// separator with a distinct (non-folder) icon; treated as temporary.
    var isTidy: Bool

    init(id: UUID = UUID(),
         name: String,
         symbol: String = "folder",
         isExpanded: Bool = true,
         tabIDs: [UUID] = [],
         isTidy: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isExpanded = isExpanded
        self.tabIDs = tabIDs
        self.isTidy = isTidy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, isExpanded, tabIDs, isTidy
    }

    // Custom decode so folders saved before `isTidy` existed still load
    // (synthesized Codable would throw on the missing key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "folder"
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        tabIDs = try c.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? []
        isTidy = try c.decodeIfPresent(Bool.self, forKey: .isTidy) ?? false
    }
}
