import Foundation
import Testing

@testable import LaunchdOps

struct MachOSignatureTests {
  @Test func textIsNotMachO() {
    #expect(MachOSignature.inspect(Data("#!/bin/zsh\necho hi\n".utf8)) == .notMachO)
    #expect(MachOSignature.inspect(Data()) == .notMachO)
  }

  @Test func javaClassFileIsNotMachO() {
    // 0xCAFEBABE followed by a class file version (minor 0, major 65).
    #expect(MachOSignature.inspect(Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41])) == .notMachO)
  }

  @Test func detectsEachSignatureKind() {
    let unhardened = MachOFixture.thin(signature: .developer(runtime: false))
    let hardened = MachOFixture.thin(signature: .developer(runtime: true))
    #expect(MachOSignature.inspect(MachOFixture.thin(signature: nil)) == .unsigned(arm64: true))
    #expect(MachOSignature.inspect(MachOFixture.thin(signature: nil, cpuType: intel)) == .unsigned(arm64: false))
    #expect(MachOSignature.inspect(MachOFixture.thin(signature: .adHoc)) == .adHoc)
    // Linker-signed arm64 code: CS_ADHOC clear and no CMS slot.
    #expect(MachOSignature.inspect(MachOFixture.thin(signature: .linkerSigned)) == .adHoc)
    #expect(MachOSignature.inspect(unhardened) == .developerSigned(hardenedRuntime: false))
    #expect(MachOSignature.inspect(hardened) == .developerSigned(hardenedRuntime: true))
  }

  @Test func universalBinaryReportsItsWeakestSlice() {
    let hardened = MachOFixture.thin(signature: .developer(runtime: true))
    let fat = MachOFixture.fat([hardened, MachOFixture.thin(signature: nil)])
    #expect(MachOSignature.inspect(fat) == .unsigned(arm64: true))
    let mixed = MachOFixture.fat([MachOFixture.thin(signature: nil, cpuType: intel), MachOFixture.thin(signature: nil)])
    #expect(MachOSignature.inspect(mixed) == .unsigned(arm64: true))
    let signed = MachOFixture.fat([hardened])
    #expect(MachOSignature.inspect(signed) == .developerSigned(hardenedRuntime: true))
  }

  @Test func truncatedBinaryIsNotReported() {
    #expect(MachOSignature.inspect(MachOFixture.thin(signature: .adHoc).prefix(40)) == .notMachO)
  }

  @Test func malformedHeadersStopEarly() {
    let signed = MachOFixture.thin(signature: .adHoc)
    // ncmds far beyond what sizeofcmds holds.
    #expect(MachOSignature.inspect(MachOFixture.patching(signed, at: 16, with: 0xFFFF_FFFF)) == .adHoc)
    let unsigned = MachOFixture.thin(signature: nil)
    #expect(MachOSignature.inspect(MachOFixture.patching(unsigned, at: 16, with: 0xFFFF_FFFF)) == .notMachO)
    // A load command smaller than its own header.
    #expect(MachOSignature.inspect(MachOFixture.patching(signed, at: 36, with: 4)) == .notMachO)
    // A universal binary whose 64-bit slice offset is Int.max.
    var fat = Data()
    for value: UInt32 in [0xCAFE_BABF, 1, 0x0100_000C, 0, 0x7FFF_FFFF, 0xFFFF_FFFF, 0, 0, 0, 0] {
      fat.append(contentsOf: [value].blob)
    }
    #expect(MachOSignature.inspect(fat) == .notMachO)
  }

  @Test func validatorWarnsAboutUnsignedPrograms() {
    var project = project(with: MachOFixture.thin(signature: nil))
    #expect(Validator.validate(project).contains { $0.rule == "payload.binary-unsigned" })
    project.payload[0].contents = Data("#!/bin/zsh\n".utf8)
    #expect(!Validator.validate(project).contains { $0.rule == "payload.binary-unsigned" })
  }

  @Test func validatorWarnsBeforeNotarizingWeakSignatures() {
    var project = project(with: MachOFixture.thin(signature: .adHoc))
    #expect(!Validator.validate(project).contains { $0.rule == "payload.binary-notarization" })
    project.settings.signingIdentity = "Developer ID Installer: Example (ABCDE12345)"
    #expect(Validator.validate(project).contains { $0.rule == "payload.binary-notarization" })
    project.payload[0].contents = MachOFixture.thin(signature: .developer(runtime: false))
    #expect(Validator.validate(project).contains { $0.rule == "payload.binary-notarization" })
    project.payload[0].contents = MachOFixture.thin(signature: .developer(runtime: true))
    #expect(!Validator.validate(project).contains { $0.rule.hasPrefix("payload.binary") })
  }

  private let intel: UInt32 = 0x0100_0007  // CPU_TYPE_X86_64

  private func project(with contents: Data) -> Project {
    var project = Project()
    var job = LaunchJob(context: .daemon, label: "com.example.tool")
    job.program = "/usr/local/libexec/tool"
    project.jobs = [job]
    project.payload = [PayloadFile(name: "tool", destination: "/usr/local/libexec", mode: 0o755, contents: contents)]
    return project
  }
}

/// Minimal Mach-O files with just the structures `MachOSignature` reads.
private enum MachOFixture {
  enum Signature {
    case adHoc
    case linkerSigned
    case developer(runtime: Bool)
  }

  static func patching(_ data: Data, at offset: Int, with value: UInt32) -> Data {
    var copy = data
    Swift.withUnsafeBytes(of: value.littleEndian) { copy.replaceSubrange(offset..<offset + 4, with: $0) }
    return copy
  }

  static func thin(signature: Signature?, cpuType: UInt32 = 0x0100_000C) -> Data {
    let headerSize = 32
    let commandSize = 16
    let signatureOffset = headerSize + commandSize
    var data = Data()
    data.append(le: 0xFEED_FACF)  // MH_MAGIC_64
    data.append(le: cpuType)
    data.append(le: 0)
    data.append(le: 2)  // MH_EXECUTE
    data.append(le: signature == nil ? 0 : 1)
    data.append(le: signature == nil ? 0 : UInt32(commandSize))
    data.append(le: 0)
    data.append(le: 0)
    guard let signature else { return data }
    data.append(le: 0x1D)  // LC_CODE_SIGNATURE
    data.append(le: UInt32(commandSize))
    data.append(le: UInt32(signatureOffset))
    data.append(le: 0)

    let flags: UInt32
    let cms: Data
    switch signature {
    case .adHoc:
      (flags, cms) = (0x2, Data())
    case .linkerSigned:
      (flags, cms) = (0x2_0000, Data())
    case .developer(let runtime):
      (flags, cms) = (runtime ? 0x1_0000 : 0, Data(repeating: 0x30, count: 16))
    }
    let hasWrapper = { if case .linkerSigned = signature { false } else { true } }()
    let directory = [0xFADE_0C02, 20, 0x20400, flags, 0].blob
    let wrapper = hasWrapper ? Data([0xFADE_0B01, UInt32(8 + cms.count)].blob) + cms : Data()
    let slots = hasWrapper ? 2 : 1
    let indexEnd = 12 + slots * 8
    var blob = Data()
    blob.append(be: 0xFADE_0CC0)
    blob.append(be: UInt32(indexEnd + directory.count + wrapper.count))
    blob.append(be: UInt32(slots))
    blob.append(be: 0)
    blob.append(be: UInt32(indexEnd))
    if hasWrapper {
      blob.append(be: 0x10000)
      blob.append(be: UInt32(indexEnd + directory.count))
    }
    data.append(blob + directory + wrapper)
    return data
  }

  static func fat(_ slices: [Data]) -> Data {
    var data = Data()
    data.append(be: 0xCAFE_BABE)
    data.append(be: UInt32(slices.count))
    var offset = 8 + slices.count * 20
    for slice in slices {
      data.append(contentsOf: [0x0100_000C, 0, UInt32(offset), UInt32(slice.count), 0].blob)
      offset += slice.count
    }
    for slice in slices {
      data.append(slice)
    }
    return data
  }
}

extension [UInt32] {
  fileprivate var blob: Data {
    var data = Data()
    for value in self {
      data.append(be: value)
    }
    return data
  }
}

extension Data {
  fileprivate mutating func append(le value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }

  fileprivate mutating func append(be value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
