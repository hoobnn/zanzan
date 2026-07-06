//
//  ContentView.swift
//  zanzan
//
//  Created by hoobnn on 2026/7/6.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "攒攒",
            systemImage: "wallet.bifold",
            description: Text("记账功能开发中")
        )
    }
}

#Preview {
    ContentView()
}
