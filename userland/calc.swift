// calc.swift — an interactive expression-calculator REPL for swift-os.
//
// This is the first EL0 program written in *idiomatic* Embedded Swift rather
// than hand-rolled UnsafePointer byte-twiddling: it exercises the high-level
// runtime end to end on our own syscall ABI — classes + ARC, an indirect
// (recursive) enum AST, `Array`/`String`/`Dictionary`, generics, closures, a
// protocol with a witness table, and `print()` with String interpolation. It
// proved out the bridge's new free-capable allocator (a long-lived REPL that
// builds and drops an AST per line churns the heap continuously).
//
// Grammar:
//   statement := IDENT '=' expr | expr
//   expr      := term (('+' | '-') term)*
//   term      := factor (('*' | '/' | '%') factor)*
//   factor    := '-' factor | '(' expr ')' | INT | IDENT
//
// Integer (Int64) arithmetic only — the core deliberately avoids floating point
// so acceptance does not hinge on soft-float/compiler-rt (FP is permitted at EL0
// but unused here; see docs/NOTES.md).

// ---- tokens ----------------------------------------------------------------

enum Token: Equatable {
    case int(Int64)
    case ident(String)
    case plus, minus, star, slash, percent
    case lparen, rparen, assign
}

private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
private func isAlpha(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F // A-Z a-z _
}

// Lex a line (its UTF-8 bytes) into tokens, or nil on an illegal character.
private func lex(_ src: [UInt8]) -> [Token]? {
    var toks: [Token] = []
    var i = 0
    let n = src.count
    while i < n {
        let c = src[i]
        if c == 0x20 || c == 0x09 { i += 1; continue }            // space / tab
        if isDigit(c) {
            var v: Int64 = 0
            while i < n && isDigit(src[i]) { v = v * 10 + Int64(src[i] - 0x30); i += 1 }
            toks.append(.int(v))
            continue
        }
        if isAlpha(c) {
            var name: [UInt8] = []
            while i < n && (isAlpha(src[i]) || isDigit(src[i])) { name.append(src[i]); i += 1 }
            toks.append(.ident(String(decoding: name, as: UTF8.self)))
            continue
        }
        switch c {
        case 0x2B: toks.append(.plus)
        case 0x2D: toks.append(.minus)
        case 0x2A: toks.append(.star)
        case 0x2F: toks.append(.slash)
        case 0x25: toks.append(.percent)
        case 0x28: toks.append(.lparen)
        case 0x29: toks.append(.rparen)
        case 0x3D: toks.append(.assign)
        default: return nil
        }
        i += 1
    }
    return toks
}

// ---- AST (indirect enum → heap-boxed → ARC) --------------------------------

indirect enum Expr {
    case num(Int64)
    case variable(String)
    case neg(Expr)
    case binop(Token, Expr, Expr)
    case assign(String, Expr)
}

// A protocol with a witness table, conformed by the recursive enum: counting the
// nodes walks the boxed AST (more ARC traffic) and is reached generically below.
protocol NodeCounting {
    var nodeCount: Int { get }
}

extension Expr: NodeCounting {
    var nodeCount: Int {
        switch self {
        case .num, .variable: return 1
        case .neg(let x): return 1 + x.nodeCount
        case .assign(_, let x): return 1 + x.nodeCount
        case .binop(_, let a, let b): return 1 + a.nodeCount + b.nodeCount
        }
    }
}

private func reportTree<T: NodeCounting>(_ x: T) {
    print("  (ast nodes: \(x.nodeCount))")
}

// ---- parser (recursive descent) --------------------------------------------

private struct Parser {
    let toks: [Token]
    var pos = 0

    func peek() -> Token? { pos < toks.count ? toks[pos] : nil }
    mutating func advance() { pos += 1 }
    var atEnd: Bool { pos >= toks.count }

    // statement := IDENT '=' expr | expr
    mutating func parseStatement() -> Expr? {
        if case .ident(let name)? = peek(), pos + 1 < toks.count, toks[pos + 1] == .assign {
            advance(); advance() // consume IDENT '='
            guard let rhs = parseExpr() else { return nil }
            return .assign(name, rhs)
        }
        return parseExpr()
    }

    mutating func parseExpr() -> Expr? {
        guard var lhs = parseTerm() else { return nil }
        while let t = peek(), t == .plus || t == .minus {
            advance()
            guard let rhs = parseTerm() else { return nil }
            lhs = .binop(t, lhs, rhs)
        }
        return lhs
    }

    mutating func parseTerm() -> Expr? {
        guard var lhs = parseFactor() else { return nil }
        while let t = peek(), t == .star || t == .slash || t == .percent {
            advance()
            guard let rhs = parseFactor() else { return nil }
            lhs = .binop(t, lhs, rhs)
        }
        return lhs
    }

    mutating func parseFactor() -> Expr? {
        guard let t = peek() else { return nil }
        switch t {
        case .minus:
            advance()
            guard let x = parseFactor() else { return nil }
            return .neg(x)
        case .lparen:
            advance()
            guard let e = parseExpr() else { return nil }
            guard peek() == .rparen else { return nil }
            advance()
            return e
        case .int(let v):
            advance()
            return .num(v)
        case .ident(let name):
            advance()
            return .variable(name)
        default:
            return nil
        }
    }
}

// ---- environment (class + ARC + Dictionary) --------------------------------

final class Env {
    private var vars: [String: Int64] = [:]
    func get(_ k: String) -> Int64? { vars[k] }
    func set(_ k: String, _ v: Int64) { vars[k] = v }
    var count: Int { vars.count }
}

// ---- evaluator -------------------------------------------------------------

enum EvalResult {
    case ok(Int64)
    case err(String)
}

private func eval(_ e: Expr, _ env: Env) -> EvalResult {
    switch e {
    case .num(let n):
        return .ok(n)
    case .variable(let name):
        if let v = env.get(name) { return .ok(v) }
        return .err("unknown variable '\(name)'")
    case .neg(let x):
        switch eval(x, env) {
        case .ok(let v): return .ok(0 - v)
        case .err(let m): return .err(m)
        }
    case .assign(let name, let x):
        switch eval(x, env) {
        case .ok(let v): env.set(name, v); return .ok(v)
        case .err(let m): return .err(m)
        }
    case .binop(let op, let a, let b):
        let lr = eval(a, env)
        guard case .ok(let l) = lr else { return lr }
        let rr = eval(b, env)
        guard case .ok(let r) = rr else { return rr }
        switch op {
        case .plus: return .ok(l + r)
        case .minus: return .ok(l - r)
        case .star: return .ok(l * r)
        case .slash:
            if r == 0 { return .err("division by zero") }
            return .ok(l / r)
        case .percent:
            if r == 0 { return .err("division by zero") }
            return .ok(l % r)
        default: return .err("bad operator")
        }
    }
}

// ---- a generic helper used with a closure ----------------------------------

private func genericFold<T>(_ xs: [T], _ initial: T, _ combine: (T, T) -> T) -> T {
    var acc = initial
    for x in xs { acc = combine(acc, x) }
    return acc
}

// ---- input -----------------------------------------------------------------

// Read one line from stdin (canonical tty mode returns a whole line per read).
// Returns nil at EOF.
private func readREPLLine() -> String? {
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
    let env = Env()
    var history: [Int64] = []

    print("swift-os calc — Int64 expression REPL")
    print("type an expression, `name = expr` to assign, `:help` for commands")

    while let line = readREPLLine() {
        if line.isEmpty { continue }

        if line.first == ":" {
            switch line {
            case ":q", ":quit":
                print("bye")
                return 0
            case ":help":
                print("commands: :q quit  :mem heap break  :vars var count  :sum sum results  :help")
            case ":mem":
                // Proves the allocator frees: the break stays bounded across a
                // long churn of allocations (see tests/calc_test.sh).
                print("heap break: \(swiftos_heap_break())")
            case ":vars":
                print("variables: \(env.count)")
            case ":sum":
                let total = genericFold(history, 0, { $0 + $1 })
                print("sum of \(history.count) results: \(total)")
            default:
                print("error: unknown command (try :help)")
            }
            continue
        }

        guard let toks = lex(Array(line.utf8)) else {
            print("error: illegal character")
            continue
        }
        if toks.isEmpty { continue }

        var parser = Parser(toks: toks)
        guard let ast = parser.parseStatement(), parser.atEnd else {
            print("error: parse error")
            continue
        }

        switch eval(ast, env) {
        case .ok(let v):
            history.append(v)
            print("= \(v)")
        case .err(let m):
            reportTree(ast)
            print("error: \(m)")
        }
    }
    return 0
}
