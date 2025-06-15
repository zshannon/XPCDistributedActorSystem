import ServiceManagement

extension SMAppService.Status {
    var description: String {
        switch self {
        case .notRegistered:
            "not registered"
        case .enabled:
            "enabled"
        case .requiresApproval:
            "requires approval"
        case .notFound:
            "not found"
        default:
            "unknown"
        }
    }
}
