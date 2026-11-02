import CryptoKit
import Foundation

/// Signs a package's table of contents. The concrete signer uses the keychain and lives outside Generators.
protocol PackageSigner: Sendable {
  /// DER certificates, leaf first.
  var certificates: [Data] { get }
  /// Length of every RSA signature, in bytes (the key size).
  var rsaSignatureLength: Int { get }
  /// RSA PKCS #1 v1.5 signature over a SHA-1 digest.
  func rsaSignature(forDigest digest: Data) throws -> Data
  /// Detached CMS signature over the digest bytes.
  func cmsSignature(forDigest digest: Data) throws -> Data
  /// Expected length of a CMS signature, used to lay out the archive before signing. A wrong guess costs one
  /// more CMS signature, not a failed export.
  var expectedCMSSignatureLength: Int { get }
}

extension PackageSigner {
  var expectedCMSSignatureLength: Int { estimatedCMSSignatureLength }

  /// CMS SignedData holds the certificates and one RSA signature, plus a few hundred bytes of structure.
  var estimatedCMSSignatureLength: Int {
    certificates.reduce(0) { $0 + $1.count } + rsaSignatureLength + 512
  }
}

enum XarWriterError: LocalizedError {
  case signatureSizeChanged

  var errorDescription: String? {
    "The package signature changed size while signing. Try exporting again."
  }
}

/// A file or directory inside a xar archive.
struct XarEntry: Sendable {
  enum Kind: Sendable {
    case file(Data)
    case directory([XarEntry])
  }

  var name: String
  var kind: Kind
  var permissions = 0o644
}

/// Writes xar archives, the container format of flat installer packages.
///
/// Layout: a 28-byte header, the zlib-compressed XML table of contents, then the heap. The heap starts
/// with the SHA-1 of the compressed table of contents, followed by the signatures (when signed) and
/// the file data, stored uncompressed.
enum XarWriter {
  private static let sha1Length = 20

  /// The table of contents records each signature's size, and the signed digest covers the table of contents,
  /// so the CMS size must be known before signing. Its length depends only on the signer, so the archive is laid
  /// out with the expected length and signed; if the CMS signature comes out a different size, it is laid out
  /// again with that size. Each private-key use can show a keychain prompt, so there is no separate probe.
  static func archive(_ entries: [XarEntry], signer: (any PackageSigner)? = nil) throws -> Data {
    guard let signer else {
      return try assemble(try layout(entries, signer: nil, signatures: nil))
    }
    var cmsLength = signer.expectedCMSSignatureLength
    for _ in 0..<2 {
      var archive = try layout(entries, signer: signer, signatures: (signer.rsaSignatureLength, cmsLength))
      let cms = try signer.cmsSignature(forDigest: archive.digest)
      guard cms.count == cmsLength else {
        cmsLength = cms.count
        continue
      }
      let rsa = try signer.rsaSignature(forDigest: archive.digest)
      guard rsa.count == signer.rsaSignatureLength else { throw XarWriterError.signatureSizeChanged }
      archive.heap.replaceSubrange(sha1Length..<(sha1Length + rsa.count), with: rsa)
      archive.heap.replaceSubrange((sha1Length + rsa.count)..<(sha1Length + rsa.count + cms.count), with: cms)
      return try assemble(archive)
    }
    throw XarWriterError.signatureSizeChanged
  }

  private struct Layout {
    let tocLength: Int
    let compressedTOC: Data
    let digest: Data
    var heap: Data
  }

  /// The table of contents and heap, with zeroed space for signatures of the given lengths.
  private static func layout(
    _ entries: [XarEntry],
    signer: (any PackageSigner)?,
    signatures: (rsaLength: Int, cmsLength: Int)?
  ) throws -> Layout {
    var heap = Data(count: sha1Length)
    var signatureXML = ""
    if let signer, let signatures {
      let keyInfo = keyInfoXML(signer.certificates)
      signatureXML = """
        <signature style="RSA"><offset>\(heap.count)</offset><size>\(signatures.rsaLength)</size>\(keyInfo)</signature>
        """
      heap.append(Data(count: signatures.rsaLength))
      signatureXML += """
        <x-signature style="CMS"><offset>\(heap.count)</offset><size>\(signatures.cmsLength)</size>\(keyInfo)</x-signature>
        """
      heap.append(Data(count: signatures.cmsLength))
    }

    var nextID = 1
    let filesXML = entries.map { fileXML($0, heap: &heap, nextID: &nextID) }.joined()
    let toc = """
      <?xml version="1.0" encoding="UTF-8"?>
      <xar><toc><checksum style="sha1"><offset>0</offset><size>\(sha1Length)</size></checksum>\
      \(signatureXML)\(filesXML)</toc></xar>
      """
    let tocData = Data(toc.utf8)
    let compressedTOC = try PackageCompression.zlib(tocData)
    let digest = Data(Insecure.SHA1.hash(data: compressedTOC))
    heap.replaceSubrange(0..<sha1Length, with: digest)
    return Layout(tocLength: tocData.count, compressedTOC: compressedTOC, digest: digest, heap: heap)
  }

  private static func assemble(_ layout: Layout) throws -> Data {
    var output = Data("xar!".utf8)
    output.appendBigEndian(UInt16(28))
    output.appendBigEndian(UInt16(1))
    output.appendBigEndian(UInt64(layout.compressedTOC.count))
    output.appendBigEndian(UInt64(layout.tocLength))
    output.appendBigEndian(UInt32(1))  // checksum algorithm: SHA-1
    output.append(layout.compressedTOC)
    output.append(layout.heap)
    return output
  }

  private static func fileXML(_ entry: XarEntry, heap: inout Data, nextID: inout Int) -> String {
    let id = nextID
    nextID += 1
    let ownership = "<uid>0</uid><gid>0</gid><user>root</user><group>wheel</group>"
    let mode = "<mode>\(String(format: "%04o", entry.permissions))</mode>"
    switch entry.kind {
    case .file(let contents):
      let offset = heap.count
      heap.append(contents)
      let checksum = Insecure.SHA1.hash(data: contents).map { String(format: "%02x", $0) }.joined()
      return """
        <file id="\(id)"><data><length>\(contents.count)</length><offset>\(offset)</offset>\
        <size>\(contents.count)</size><encoding style="application/octet-stream"/>\
        <extracted-checksum style="sha1">\(checksum)</extracted-checksum>\
        <archived-checksum style="sha1">\(checksum)</archived-checksum></data>\
        \(mode)\(ownership)<type>file</type><name>\(XML.escaped(entry.name))</name></file>
        """
    case .directory(let children):
      let childXML = children.map { fileXML($0, heap: &heap, nextID: &nextID) }.joined()
      return """
        <file id="\(id)">\(mode)\(ownership)<type>directory</type><name>\(XML.escaped(entry.name))</name>\
        \(childXML)</file>
        """
    }
  }

  private static func keyInfoXML(_ certificates: [Data]) -> String {
    let certs = certificates.map { "<X509Certificate>\($0.base64EncodedString())</X509Certificate>" }.joined()
    return #"<KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data>"# + certs + "</X509Data></KeyInfo>"
  }
}

enum XML {
  static func escaped(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
