import Foundation

public struct InvocationResponse<T>: Codable, Sendable where T: Codable & Sendable {
    var error: String?
    var value: T?
}

public extension InvocationResponse where T == Never {
    init(error: Swift.Error) {
        self.error = String(describing: error)
    }
}

public extension InvocationResponse where T == Never {
    init() {}
}

public extension InvocationResponse where T == Data {
    init(error: Swift.Error) {
        self.error = String(describing: error)
    }
}

public extension InvocationResponse where T == Data {
    init(value: Data) {
        self.value = value
    }

    init(error: String?, value: Data?) {
        self.error = error
        self.value = value
    }
}
