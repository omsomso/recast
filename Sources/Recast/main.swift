import Foundation
import RecastCore
let args = Array(CommandLine.arguments.dropFirst())
let input = URL(fileURLWithPath: args[0])
for (name, mode) in [("cvbr", AACMode.constrainedVBR), ("vbr", .vbr), ("cbr", .cbr), ("abr", .abr)] {
    var settings = ConversionSettings()
    settings.format = .aac
    settings.aacMode = mode
    if args.count > 1 { settings.copyTags = false }
    let output = input.deletingLastPathComponent().appendingPathComponent("aac-\(name).m4a")
    let outcome = try! Converter.convert(input: input, to: output, settings: settings)
    print(name, outcome.bytes, try! AudioProbe.info(output).summary)
}
