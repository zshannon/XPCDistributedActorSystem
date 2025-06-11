import Calculator
import ServiceManagement
import SwiftUI
import XPCDistributedActorSystem

struct ContentView: View {
    let service = SMAppService.daemon(plistName: "com.yourcompany.XPCDistributedActorExample.CalculatorDaemon.plist")

    @State private var xpc: XPCDistributedActorClient?
    @State private var calculator: Calculator? // remote actor in the daemon
    @State private var output: String = "No calculation done"
    @State private var daemonStatus = "Unknown"

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 10) {
                Label("Important", systemImage: "exclamationmark.triangle")
                    .bold()
                    .font(.title)
                Text(
                    "If you click \"Install Launch Daemon\", a LaunchDaemon process with root privileges will be installed and started. This process will be kept running and automatically restarted if you don't uninstall it by clicking \"Uninstall Launch Daemon\".",
                )
                Text("Make sure to uninstall it when you're done testing.")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background(.orange)
            Form {
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
                            .disabled(service.status != .notRegistered && service.status != .notFound)
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
                                        let number1 = Int.random(in: 0 ..< 1000)
                                        let number2 = Int.random(in: 0 ..< 1000)
                                        let result = try await calculator.add(number1, number2)
                                        output = "\(number1) + \(number2) = \(result)"
                                    } catch {
                                        output = "Failed to calculate: \(error.localizedDescription)"
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
                        }
                    }
                    LabeledContent("Response") {
                        Text(output)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .onAppear(perform: updateDaemonStatus)
        .task {
            while true {
                // TODO: Find a better way to check the service status than this loop
                try? await Task.sleep(for: .seconds(1), tolerance: .seconds(1))
                let newDaemonStatus = service.status.description
                if newDaemonStatus != daemonStatus {
                    updateDaemonStatus()
                }
            }
        }
    }

    func updateDaemonStatus() {
        daemonStatus = service.status.description

        if service.status == .enabled {
            Task {
                await configureXPCService()
            }
        } else {
            xpc = nil
            calculator = nil
        }
    }

    func configureXPCService() async {
        let codeSigningRequirement: CodeSigningRequirement

        do {
            codeSigningRequirement = try CodeSigningRequirement.sameTeam
        } catch {
            print("Failed to set up code signing requirement:", error.localizedDescription)
            return
        }

        do {
            let xpc = try await XPCDistributedActorClient(
                connectionType: .daemon(serviceName: daemonXPCServiceIdentifier),
                codeSigningRequirement: codeSigningRequirement,
            )
            self.xpc = xpc

            calculator = try Calculator.resolve(id: .init(), using: xpc)
        } catch {
            print("Failed to set up XPC client or resolve remote actor:", error.localizedDescription)
        }
    }
}

#Preview {
    ContentView()
}
