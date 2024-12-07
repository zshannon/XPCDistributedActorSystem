@preconcurrency import XPC

public actor XPCDaemonListener
{
    let actorSystem: XPCDistributedActorSystem
    var lastConnection: XPCConnection?
    private var listener: xpc_connection_t?
    
    public init(daemonServiceName: String, actorSystem: XPCDistributedActorSystem) throws
    {
        self.actorSystem = actorSystem
        let listener = xpc_connection_create_mach_service(daemonServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        self.listener = listener
        xpc_connection_set_event_handler(listener) { event in
            // TODO: Check if the event is an error or an incoming connection
            let connection = XPCConnection(incomingConnection: event, actorSystem: actorSystem)
            Task {
                await self.setConnection(connection)
            }
        }
        xpc_connection_activate(listener)
        
        // TODO: Handle errors if the listener fails to be created
    }
    
    func setConnection(_ connection: XPCConnection) async
    {
        if let lastConnection {
            await lastConnection.close()
        }
        self.lastConnection = connection
    }
}
