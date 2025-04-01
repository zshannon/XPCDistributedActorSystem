import Security

struct SigningInformationExtractor
{
    enum Error: Swift.Error
    {
        case secError(OSStatus)
        case otherError(String)
        
        var localizedDescription: String
        {
            switch self {
            case .secError(let status):
               if let specificErrorMessage = SecCopyErrorMessageString(status, nil) as? String {
                   specificErrorMessage
               } else {
                   "Security function failed with status \(status)"
               }
            case .otherError(let message):
                message
            }
        }
    }
    
    static func withStatusCheck(_ status: OSStatus) throws
    {
        guard status == errSecSuccess else {
            throw Error.secError(status)
        }
    }
    
    static func getCurrentTeamID() throws -> String
    {
        var currentCode: SecCode?
        try withStatusCheck(SecCodeCopySelf(SecCSFlags(), &currentCode))
        guard let currentCode else {
            throw Error.otherError("Failed to get current code for unknown reason while trying to extract team ID")
        }
        
        var codeOnDisk: SecStaticCode?
        try withStatusCheck(SecCodeCopyStaticCode(currentCode, SecCSFlags(), &codeOnDisk))
        guard let codeOnDisk else {
            throw Error.otherError("Failed to get code on disk for unknown reason while trying to extract team ID")
        }
        
        var extractedSigningInformation: CFDictionary?
        let signingInformationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        try withStatusCheck(SecCodeCopySigningInformation(codeOnDisk, signingInformationFlags, &extractedSigningInformation))
        guard let extractedSigningInformation = extractedSigningInformation as? [String: Any], let teamIdentifier = extractedSigningInformation[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw Error.otherError("Failed to copy code signing information for unknown reason while trying to extract team ID")
        }

        return teamIdentifier
    }
}
