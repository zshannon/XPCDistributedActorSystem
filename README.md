# XPCDistributedActorSystem

An _experimental_ [DistributedActorSystem](https://developer.apple.com/documentation/distributed/distributedactorsystem) for Swift that uses XPC as a transport layer.

# Supported platforms

Works on macOS only (because XPC support on iOS is extremely limited).

# Known issues

* ⚠️ Lacks XPC security mechanisms
* ⚠️ Barely tested
* Actor ID assignment needs improvement

# Usage

Two example projects are included (for an XPC Service and a Launch Daemon). They are the best starting point to see how this system works.

To run the examples, you need to set your development team by duplicating the file `Config.xcconfig.template`, renaming it to `Config.xcconfig` and update it with your Development Team Identifier:
 
```
DEVELOPMENT_TEAM = <YOUR_DEVELOPMENT_TEAM_IDENTIFIER>
```

Short code sample:

### In the App:

```swift
import XPCDistributedActorSystem
import Calculator

// Set up the system
let xpc = XPCDistributedActorSystem(mode: .connectingToXPCService(serviceName: yourServiceName))
let calculator = try Calculator.resolve(id: .init(1), using: xpc)

// Run function in the XPC service and print the result
let result = try await calculator.add(number1, number2)
print(result)

```

### In the XPC Service:

```swift
import XPCDistributedActorSystem
import Calculator

let system = XPCDistributedActorSystem(mode: .receivingConnections)
let calculator = Calculator(actorSystem: system)
let listener = try XPCServiceListener(actorSystem: system)
listener.run()
```

### Required project structure:

All the types referenced by the distributed actor need to be available to both XPC endpoints – and they have to be *absolutely* identical, because demangling for the distributed actor will fail otherwise.

The easiest way is to just put the distributed actor and all types required for its functionality inside a Library, and add that Library to both targets.

# Ideas for the future

* Implement a way to share status with `@Observable`


# Contributing

Feel free to fork (see [license](LICENSE)) or contribute.
