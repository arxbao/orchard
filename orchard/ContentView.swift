//
//  ContentView.swift
//  orchard
//
//  Created by XLee7 on 2026/9/1.
//

import SwiftUI
import OrchardCore

/// Placeholder root view for the skeleton stage.
///
/// Shows the Orchard version string from the shared OrchardCore library —
/// this is the proof that the app target actually links the package
/// (Task 4 acceptance). Feature branches replace this with the real
/// container-management UI (Containers/Dashboard/...).
struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "shippingbox.fill")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Orchard \(OrchardCore.versionString)")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
