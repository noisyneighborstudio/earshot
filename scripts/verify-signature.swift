// Verifies a Sparkle EdDSA signature against a public key, as the app will.
// usage: swift verify-signature.swift <SUPublicEDKey> <edSignature> <archive>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let key = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let archive = FileManager.default.contents(atPath: args[3]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      publicKey.isValidSignature(signature, for: archive)
else { exit(1) }
