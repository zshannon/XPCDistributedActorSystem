import Distributed

public struct InvocationResultHandler: DistributedTargetInvocationResultHandler
{
    public typealias SerializationRequirement = any Codable
    
    let xpcConnection: XPCConnection
    let requestMessage: XPCMessageWithObject
    
    init(xpcConnection: XPCConnection, request: XPCMessageWithObject)
    {
        self.xpcConnection = xpcConnection
        self.requestMessage = request
    }
    
    public func onReturn<V: Codable>(value: V) async throws
    {
        let response = InvocationResponse(value: value)
        let messageToSend = try XPCMessageWithObject(from: response, replyTo: requestMessage)
        try await xpcConnection.reply(with: messageToSend)
    }
    
    public func onReturnVoid() async throws
    {
        let response = InvocationResponse<Never>()
        let messageToSend = try XPCMessageWithObject(from: response, replyTo: requestMessage)
        try await xpcConnection.reply(with: messageToSend)
    }
    
    public func onThrow<Err>(error: Err) async throws where Err: Swift.Error
    {
        let response = InvocationResponse(error: error)
        let messageToSend = try XPCMessageWithObject(from: response, replyTo: requestMessage)
        try await xpcConnection.reply(with: messageToSend)
    }
}
