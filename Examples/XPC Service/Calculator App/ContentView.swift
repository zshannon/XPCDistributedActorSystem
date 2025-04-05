import SwiftUI
import XPCDistributedActorSystem
import Calculator

struct ContentView: View
{
    @State private var xpc: XPCDistributedActorSystem?
    @State private var calculator: Calculator? // remote actor in the XPC service
    @State private var output: String = "No calculation done"
    
    var body: some View {
        VStack {
            Button("Calculate") {
                guard let calculator else { return }
                output = "Starting XPC service and calculating..."
                Task {
                    do {
                        let number1 = Int.random(in: 0..<1000)
                        let number2 = Int.random(in: 0..<1000)
                        let result = try await calculator.add(number1, number2)
                        output = "\(number1) + \(number2) = \(result)"
                    } catch {
                        output = "Failed to calculate"
                        print("Failed to execute XPC request:", error.localizedDescription)
                    }
                }
            }
            Button("Call a remote function (no output)") {
                guard let calculator else {
                    output = "Distributed actor not set up"
                    return
                }
                Task {
                    do {
                        try await calculator.justARemoteFunction()
                        output = ""
                    } catch {
                        output = "Failed to call remote function: \(error.localizedDescription)"
                    }
                }
            }
            Text(output)
        }
        .disabled(self.calculator == nil)
        .padding()
        .onAppear(perform: configureXPCService)
    }
    
    func configureXPCService()
    {
        guard let serviceIdentifier = Bundle.main.firstXPCServiceIdentifier() else {
            print("Failed to find a valid XPC service in the app's bundle.")
            return
        }

        print("Found XPC service in bundle:", serviceIdentifier)

        let codeSigningRequirement: CodeSigningRequirement
        
        do {
            codeSigningRequirement = try CodeSigningRequirement.sameTeam
        } catch {
            print("Failed to set up code signing requirement:", error.localizedDescription)
            return
        }

        let xpc = XPCDistributedActorSystem(mode: .connectingToXPCService(serviceName: serviceIdentifier), codeSigningRequirement: codeSigningRequirement)
        self.xpc = xpc
        
        do {
            self.calculator = try Calculator.resolve(id: .init(1), using: xpc)
        } catch {
            print("Failed to find remote actor:", error.localizedDescription)
        }
        
        // The XPC service process won't be launched until the first call to the remote actor
    }
}

#Preview {
    ContentView()
}
