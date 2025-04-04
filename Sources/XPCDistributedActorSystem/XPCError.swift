import Foundation
import XPC

public struct XPCError: Error, Codable, Sendable, LocalizedError
{
    public enum Category: Codable, Sendable
    {
        case connectionInterrupted
        case connectionInvalid
        case terminationImminent
        case codeSignatureCheckFailed
        case unexpectedMessageType
        case failedToGetDataFromXPCDictionary
        case failedToCreateReply
        case unknown
        case connectionNotReady
    }
    
    let category: Category
    public let nativeErrorDescription: String?
    
    public var errorDescription: String? {
        if let nativeErrorDescription {
            return nativeErrorDescription
        }
        
        return switch category {
        case .connectionInterrupted:
            "Connection interrupted"
        case .connectionInvalid:
            "Connection invalid"
        case .terminationImminent:
            "Termination imminent"
        case .codeSignatureCheckFailed:
            "Code signature check failed (or version/artifact mismatch)"
        case .unexpectedMessageType:
            "Unexpected message type"
        case .failedToGetDataFromXPCDictionary:
            "Failed to get data from XPC dictionary"
        case .failedToCreateReply:
            "Failed to create reply"
        case .unknown:
            "Unknown error"
        case .connectionNotReady:
            "Connection not ready"
        }
    }
    
    init(_ category: Category)
    {
        self.category = category
        self.nativeErrorDescription = nil
    }

    init(error: xpc_object_t)
    {
        let description: String? = if let descriptionFromXpc = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION) {
            String(cString: descriptionFromXpc)
        } else {
            nil
        }
        
        self.nativeErrorDescription = description
        
        if error === XPC_ERROR_CONNECTION_INTERRUPTED {
            self.category = .connectionInterrupted
        } else if error === XPC_ERROR_CONNECTION_INVALID {
            self.category = .connectionInvalid
        } else if error === XPC_ERROR_TERMINATION_IMMINENT {
            self.category = .terminationImminent
        } else if error === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT {
            self.category = .codeSignatureCheckFailed
        } else {
            self.category = .unknown
        }
    }
}
