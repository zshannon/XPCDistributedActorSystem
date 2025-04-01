import Security
import Foundation

public struct CodeSigningRequirement: Sendable
{
    enum Error: Swift.Error, LocalizedError {
        case invalidRequirement
        
        var errorDescription: String? {
            switch self {
            case .invalidRequirement:
                return "Invalid code signing requirement."
            }
        }
    }
    
    public static var sameTeam: CodeSigningRequirement {
        get throws {
            let teamID = try SigningInformationExtractor.getCurrentTeamID()
            let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
            return CodeSigningRequirement(requirement: requirement)
        }
    }
    
    public static let none: CodeSigningRequirement? = nil
    
    public static func custom(_ requirement: String) throws -> CodeSigningRequirement
    {
        var requirementRef: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &requirementRef)
        
        guard status == errSecSuccess else {
            throw Error.invalidRequirement
        }
            
        return .init(requirement: requirement)
    }
    
    let requirement: String
    
    init(requirement: String)
    {
        self.requirement = requirement
    }
}
