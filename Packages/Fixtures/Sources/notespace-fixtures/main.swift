import FixtureGen
import Foundation
import InkModel

// notespace-fixtures: writes a deterministic synthetic notebook package (ARCHITECTURE.md §12).

let usage = """
usage: notespace-fixtures --pages N --out DIR [--seed S] [--strokes-per-page K] [--theme white|cream|night]
                          [--paper blank|lined|dotted|grid|cornell] [--name NAME] [--force]

Writes DIR/NAME (default DIR/<N>-pages.nb). Same arguments → byte-identical package.
  --pages N             page count (≥ 1)
  --out DIR             output directory (created if missing)
  --seed S              seed, default 1
  --strokes-per-page K  mean strokes per page, default \(FixtureSpec.defaultStrokesPerPage) (~60 samples each)
  --theme T             paper color, default white
  --paper P             notebook paper, default picked from the seed (pages mix in other templates)
  --name NAME           package directory name
  --force               replace an existing package
"""

func write(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((text + "\n").utf8))
}

func fail(_ message: String) -> Never {
    write("error: \(message)\n\n\(usage)", to: .standardError)
    exit(2)
}

var options: [String: String] = [:]
var force = false
var arguments = CommandLine.arguments.dropFirst()
while let arg = arguments.popFirst() {
    switch arg {
    case "-h", "--help":
        write(usage)
        exit(0)
    case "--force":
        force = true
    case "--pages", "--seed", "--out", "--strokes-per-page", "--theme", "--paper", "--name":
        guard let value = arguments.popFirst() else { fail("\(arg) needs a value") }
        options[arg] = value
    default:
        fail("unknown argument \(arg)")
    }
}

guard let pagesArg = options["--pages"], let pages = Int(pagesArg), pages >= 1 else { fail("--pages N (≥ 1) is required") }
guard let out = options["--out"] else { fail("--out DIR is required") }
var spec = FixtureSpec(pages: pages)
if let value = options["--seed"] {
    guard let seed = UInt64(value) else { fail("--seed must be a non-negative integer") }
    spec.seed = seed
}

if let value = options["--strokes-per-page"] {
    guard let k = Int(value), k >= 0 else { fail("--strokes-per-page must be a non-negative integer") }
    spec.strokesPerPage = k
}

if let value = options["--theme"] {
    guard let theme = PaperTheme(rawValue: value) else { fail("unknown theme \(value)") }
    spec.theme = theme
}

if let value = options["--paper"] {
    guard let paper = PaperStyle(rawValue: value) else { fail("unknown paper \(value)") }
    spec.paper = paper
}

let generator = FixtureGenerator(spec)
let directory = URL(filePath: out, directoryHint: .isDirectory)
let url = directory.appending(path: options["--name"] ?? generator.defaultPackageName, directoryHint: .isDirectory)
let fm = FileManager.default
do {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    if force, fm.fileExists(atPath: url.path(percentEncoded: false)) {
        try fm.removeItem(at: url)
    }
} catch {
    fail("\(error)")
}

let clock = ContinuousClock()
let start = clock.now
let report: FixtureReport
do {
    report = try generator.write(to: url)
} catch {
    write("error: \(error)", to: .standardError)
    exit(1)
}

let elapsed = clock.now - start
let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
write(String(
    format: "%@: %d pages, %d strokes, %d samples (%.1f/stroke), %.1f MB in %.2f s",
    url.relativePath, pages, report.strokes, report.samples,
    Double(report.samples) / Double(max(1, report.strokes)), Double(report.bytes) / 1e6, seconds
))
