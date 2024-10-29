public struct InvocationResponse<T>: Codable where T: Codable
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
