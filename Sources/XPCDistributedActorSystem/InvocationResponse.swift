import Foundation

public struct InvocationResponse<T>: Codable, Sendable where T: Codable & Sendable
{
    var error: String?
    var value: T?
}

extension InvocationResponse where T == Never
{
    public init(error: Swift.Error)
    {
        self.error = String(describing: error)
    }
}

extension InvocationResponse where T == Never
{
    public init() {}
}

extension InvocationResponse where T == Data
{
    public init(error: Swift.Error)
    {
        self.error = String(describing: error)
    }
}

extension InvocationResponse where T == Data
{
    public init(value: Data)
    {
        self.value = value
    }
    
    public init(error: String?, value: Data?)
    {
        self.error = error
        self.value = value
    }
}
