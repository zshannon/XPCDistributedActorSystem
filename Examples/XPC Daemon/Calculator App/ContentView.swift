import SwiftUI
import XPCDistributedActorSystem
import Calculator
import ServiceManagement

struct ContentView: View
{
    let service = SMAppService.daemon(plistName: "com.yourcompany.XPCDistributedActorExample.CalculatorDaemon.plist")

    @State private var xpc: XPCDistributedActorSystem?
    @State private var calculator: Calculator? // remote actor in the daemon
    @State private var output: String = "No calculation done"
    @State private var daemonStatus = "Unknown"

    var body: some View {
        Form {
            Section("Important") {
                Label("This app installs a daemon into your system that will keep running.\rMake sure to uninstall it when you're done testing!", systemImage: "exclamationmark.triangle")
            }
            Section("Service Management (Deamon)") {
                LabeledContent("Service name") {
                    Text("\(service)")
                }
                LabeledContent("Status") {
                    HStack {
                        Text(daemonStatus)
                        if service.status == .requiresApproval {
                            Button("Open System Settings") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }
                }
                LabeledContent("Actions") {
                    HStack {
                        Button("Install Launch Daemon") {
                            do {
                                try service.register()
                            } catch {
                                print("Unable to register \(error)")
                            }
                            updateDaemonStatus()
                        }
                        .disabled(service.status != .notRegistered)
                        Button("Uninstall Launch Daemon") {
                            do {
                                try service.unregister()
                            } catch {
                                print("Unable to register \(error)")
                            }
                            updateDaemonStatus()
                        }
                        .disabled(service.status != .enabled && service.status != .requiresApproval)
                    }
                }
            }
            Section("XPC") {
                LabeledContent("Service identifier") {
                    Text("\(daemonXPCServiceIdentifier)")
                }
                LabeledContent("Actions") {
                    HStack {
                        Button("Calculate") {
                            guard let calculator else {
                                output = "Distributed actor not set up"
                                return
                            }
                            output = "Calculating..."
                            Task {
                                do {
                                    let number1 = Int.random(in: 0..<1000)
                                    let number2 = Int.random(in: 0..<1000)
                                    let result = try await calculator.add(number1, number2)
                                    output = "\(number1) + \(number2) = \(result)"
                                } catch {
                                    output = "Failed to calculate: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
                LabeledContent("Response") {
                    Text(output)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: updateDaemonStatus)
    }
    
    func updateDaemonStatus()
    {
        self.daemonStatus = service.status.description

        if service.status == .enabled {
            configureXPCService()
        } else {
            self.xpc = nil
            self.calculator = nil
        }
    }
    
    func configureXPCService()
    {
        let xpc = XPCDistributedActorSystem(mode: .connectingToDaemon(serviceName: daemonXPCServiceIdentifier))
        self.xpc = xpc
        
        do {
            self.calculator = try Calculator.resolve(id: .init(1), using: xpc)
        } catch {
            print("Failed to find remote actor:", error.localizedDescription)
        }
    }
}

#Preview {
    ContentView()
}
