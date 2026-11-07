import Foundation
import CryptoKit
import Darwin

// Opt-in maintainer tool. Never opens Keychain, prints, or replaces a private key.
guard CommandLine.arguments.count==2 else{fatalError("Usage: create_update_key PRIVATE_KEY_FILE")}
let url=URL(fileURLWithPath:CommandLine.arguments[1])
let key:Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath:url.path){
 guard let raw=Data(base64Encoded:try String(contentsOf:url,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else{fatalError("Invalid private key file")}
 key=try Curve25519.Signing.PrivateKey(rawRepresentation:raw)
}else{
 key=Curve25519.Signing.PrivateKey()
 let fd=open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
 guard fd>=0 else{fatalError("Cannot create private key file")}
 let bytes=Data((key.rawRepresentation.base64EncodedString()+"\n").utf8)
 let written=bytes.withUnsafeBytes{write(fd,$0.baseAddress,bytes.count)}
 close(fd);guard written==bytes.count else{fatalError("Cannot finish writing private key")}
}
print(key.publicKey.rawRepresentation.base64EncodedString())
