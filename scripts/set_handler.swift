// usage: set_handler <bundle-id>   — sets the default app for folders & volumes
import Foundation
import CoreServices
let bid = CommandLine.arguments[1] as NSString as CFString
for t in ["public.folder", "public.volume"] {
    let ct = t as NSString as CFString
    let st = LSSetDefaultRoleHandlerForContentType(ct, .all, bid)
    let now = (LSCopyDefaultRoleHandlerForContentType(ct, .all)?.takeRetainedValue()).map { $0 as String } ?? "?"
    print("\(t): status \(st), handler now \(now)")
}
