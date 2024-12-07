import Foundation
import XPC

public struct XPCError: Error, Codable, Sendable, LocalizedError
{
    public enum Category: Error, Codable, Sendable
    {
        case connectionInterrupted
        case connectionInvalid
        case terminationImminent
        case codeSignatureCheckFailed
        case unexpectedMessageType
        case failedToGetDataFromXPCDictionary
        case unknown
    }
    
    let category: Category
    public let errorDescription: String?

    init(error: xpc_object_t)
    {
        let description: String? = if let descriptionFromXpc = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION) {
            String(cString: descriptionFromXpc)
        } else {
            nil
        }
        
        self.errorDescription = description
        
        if error === XPC_ERROR_CONNECTION_INTERRUPTED {
            self.category = .connectionInterrupted
        } else if error === XPC_ERROR_CONNECTION_INVALID {
            self.category = .connectionInvalid
        } else if error === XPC_ERROR_TERMINATION_IMMINENT {
            self.category = .terminationImminent
        } else {
            self.category = .unknown
        }
    }
}
