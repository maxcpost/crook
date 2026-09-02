import Foundation

/// Which lines an external write touched.
///
/// Deliberately not a real diff. Trimming the common prefix and suffix and
/// calling everything between "changed" is exact when an agent rewrites a
/// contiguous region, which is the overwhelmingly common shape, and merely
/// over-broad otherwise. Over-broad is the safe direction: it highlights more
/// than moved, never less.
enum LineDiff {

    struct Result {
        let firstChanged: Int      // 1-based, inclusive
        let lastChanged: Int       // 1-based, inclusive; < first means pure deletion
        let delta: Int             // new line count minus old
        var isEmpty: Bool { firstChanged > lastChanged && delta == 0 }
    }

    static func between(_ old: String, _ new: String) -> Result? {
        if old == new { return nil }
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let firstChanged = prefix + 1
        let lastChanged = b.count - suffix
        return Result(firstChanged: firstChanged,
                      lastChanged: max(lastChanged, firstChanged - 1),
                      delta: b.count - a.count)
    }
}
