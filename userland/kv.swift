// kv.swift — an in-memory key-value store REPL for swift-os.
//
// The second *idiomatic* Embedded Swift EL0 program (after /bin/calc). Where
// calc stressed the runtime through a recursive enum AST + ARC, kv leans on the
// String/Unicode machinery: it stores arbitrary user-supplied String keys and
// values in a `Dictionary<String, String>` behind a class, so every command
// hashes (and `KEYS` sorts) text the user typed — exercising the Unicode data
// tables far harder than calc, which only hashed keys it minted itself.
//
// Commands (case-insensitive verbs):
//   SET <key> <value...>   store value (the rest of the line, spaces kept)
//   GET <key>              print the value, or "(nil)"
//   DEL <key>              remove the key; "deleted" or "(nil)"
//   KEYS                   list keys, sorted (Unicode `Comparable`), one per line
//   COUNT                  number of keys
//   :stats                 keys + total value bytes (a closure over values)
//   :mem                   heap break (proves the allocator frees under churn)
//   :help                  command list
//   :q / :quit             exit

// ---- store (class + ARC + Dictionary<String,String>) ----------------------

final class Store {
    private var map: [String: String] = [:]
    func set(_ k: String, _ v: String) { map[k] = v }
    func get(_ k: String) -> String? { map[k] }
    func del(_ k: String) -> Bool { map.removeValue(forKey: k) != nil }
    func keys() -> [String] { map.keys.sorted() }        // Unicode-ordered
    var count: Int { map.count }
    // Total UTF-8 length of every stored value — a reduce with a closure.
    var valueBytes: Int { map.values.reduce(0) { $0 + $1.utf8.count } }
}

// ---- line parsing ----------------------------------------------------------

// Split a line into at most `max` fields on runs of spaces/tabs. The final
// field keeps any interior whitespace (so `SET k a b c` stores "a b c"). Leading
// and trailing whitespace is trimmed from every field.
private func splitFields(_ line: String, max: Int) -> [String] {
    let bytes = Array(line.utf8)
    let n = bytes.count
    func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
    var fields: [String] = []
    var i = 0
    while fields.count < max - 1 {
        while i < n && isWS(bytes[i]) { i += 1 }
        if i >= n { break }
        let start = i
        while i < n && !isWS(bytes[i]) { i += 1 }
        fields.append(String(decoding: bytes[start..<i], as: UTF8.self))
    }
    while i < n && isWS(bytes[i]) { i += 1 }        // skip ws before the remainder
    if i < n {
        var end = n
        while end > i && isWS(bytes[end - 1]) { end -= 1 }
        fields.append(String(decoding: bytes[i..<end], as: UTF8.self))
    }
    return fields
}

// ---- input -----------------------------------------------------------------

// Read one line from stdin (canonical tty mode returns a whole line per read).
// Returns nil at EOF. Trims the trailing newline and surrounding whitespace.
private func readLine() -> String? {
    var buf = [UInt8](repeating: 0, count: 1024)
    let r = buf.withUnsafeMutableBytes { p in
        swiftos_read(0, p.baseAddress, UInt(p.count))
    }
    if r <= 0 { return nil }
    var n = Int(r)
    while n > 0 && (buf[n - 1] == 0x0A || buf[n - 1] == 0x0D) { n -= 1 }
    var lead = 0
    while lead < n && (buf[lead] == 0x20 || buf[lead] == 0x09) { lead += 1 }
    while n > lead && (buf[n - 1] == 0x20 || buf[n - 1] == 0x09) { n -= 1 }
    return String(decoding: buf[lead..<n], as: UTF8.self)
}

// ---- REPL ------------------------------------------------------------------

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = (argc, argv, envp)
    let store = Store()

    print("swift-os kv — in-memory key-value store")
    print("commands: SET GET DEL KEYS COUNT  (:stats :mem :help :q)")

    while let line = readLine() {
        if line.isEmpty { continue }

        // Meta commands start with ':'.
        if line.first == ":" {
            switch line {
            case ":q", ":quit":
                print("bye")
                return 0
            case ":help":
                print("SET k v | GET k | DEL k | KEYS | COUNT | :stats | :mem | :q")
            case ":mem":
                // Bounded heap across SET/DEL churn proves the allocator frees
                // (see tests/kv_test.sh).
                print("heap break: \(swiftos_heap_break())")
            case ":stats":
                print("keys: \(store.count), value bytes: \(store.valueBytes)")
            default:
                print("error: unknown command (try :help)")
            }
            continue
        }

        let parts = splitFields(line, max: 3)
        let verb = parts[0].uppercased()        // Unicode case mapping

        switch verb {
        case "SET":
            if parts.count < 3 {
                print("usage: SET <key> <value>")
            } else {
                store.set(parts[1], parts[2])
                print("OK")
            }
        case "GET":
            if parts.count < 2 {
                print("usage: GET <key>")
            } else if let v = store.get(parts[1]) {
                print(v)
            } else {
                print("(nil)")
            }
        case "DEL":
            if parts.count < 2 {
                print("usage: DEL <key>")
            } else {
                print(store.del(parts[1]) ? "deleted" : "(nil)")
            }
        case "KEYS":
            let ks = store.keys()
            if ks.isEmpty {
                print("(empty)")
            } else {
                for k in ks { print(k) }
            }
        case "COUNT":
            print("\(store.count)")
        default:
            print("error: unknown command (try :help)")
        }
    }
    return 0
}
