@preconcurrency import XPC

actor XPCConnection
{   
    enum State {
        case created
        case active
        case invalid
    }
        
    private let connection: xpc_connection_t
    private let actorSystem: XPCDistributedActorSystem
    private var state: State = .created
    
    init(incomingConnection connection: sending xpc_connection_t, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?)
    {
        self.init(connection: connection, actorSystem: actorSystem, codeSigningRequirement: codeSigningRequirement)
    }
    
    init(daemonServiceName: String, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?)
    {
        let connection = xpc_connection_create_mach_service(daemonServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        self.init(connection: connection, actorSystem: actorSystem, codeSigningRequirement: codeSigningRequirement)
    }
    
    init(serviceName: String, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?)
    {
        let connection = xpc_connection_create(serviceName, nil)
        self.init(connection: connection, actorSystem: actorSystem, codeSigningRequirement: codeSigningRequirement)
    }
    
    private init(connection: sending xpc_connection_t, actorSystem: XPCDistributedActorSystem, codeSigningRequirement: CodeSigningRequirement?)
    {
        self.connection = connection
        self.actorSystem = actorSystem
        
        if let codeSigningRequirement {
            let codeSigningRequirementStatus = xpc_connection_set_peer_code_signing_requirement(connection, codeSigningRequirement.requirement)
            guard codeSigningRequirementStatus == 0 else {
                print("Unexpectedly failed to set up code signing requirement: \(codeSigningRequirement.requirement)")
                Task {
                    await setState(.invalid)
                }
                return
            }
        }

        xpc_connection_set_event_handler(connection, handleEvent)
        xpc_connection_activate(connection)
        
        Task {
            await setState(.active)
        }
    }
    
    private func setState(_ state: State)
    {
        self.state = state
    }

    public func close()
    {
        xpc_connection_cancel(connection)
    }
    
    nonisolated func handleEvent(_ event: xpc_object_t)
    {
        Task {
            if event === XPC_ERROR_CONNECTION_INVALID {
                await self.setState(.invalid)
                return
            } else if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                // Interruptions can happen if, for example, the target process exits. However, daemons/agents are usually automatically restarted and the connection will work fine after that without having to recreate or reactivate it.
                return
            }

            actorSystem.handleIncomingInvocation(connection: self, message: XPCMessageWithObject(raw: event))
        }
    }

    deinit
    {
        xpc_connection_cancel(connection)
    }
    
    func send<ObjectToSend, ObjectToReceive>(_ objectToSend: ObjectToSend, expect: ObjectToReceive.Type) async throws -> sending ObjectToReceive where ObjectToSend: Encodable, ObjectToReceive: Decodable
    {
        guard state == .active else { throw XPCError(.connectionNotReady) }
        
        let messageToSend = try XPCMessageWithObject(from: objectToSend)
        
        let receivedMessage: xpc_object_t = try await withCheckedThrowingContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, messageToSend.raw, nil) { message in
                continuation.resume(returning: message)
            }
        }
        
        let receivedMessageWithObject = XPCMessageWithObject(raw: receivedMessage)
        let extractedObject = try receivedMessageWithObject.extract(ObjectToReceive.self)
        return extractedObject
    }
    
    func reply(with messageToSend: sending XPCMessageWithObject) throws
    {
        guard state == .active else { throw XPCError(.connectionNotReady) }

        xpc_connection_send_message(connection, messageToSend.raw)
    }
    
    func reply(to request: XPCMessageWithObject) throws
    {
        guard state == .active else { throw XPCError(.connectionNotReady) }

        guard let message = xpc_dictionary_create_reply(request.raw) else { throw XPCError(.failedToCreateReply) }
        xpc_connection_send_message(connection, message)
    }
}
