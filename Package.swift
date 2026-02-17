// swift-tools-version: 5.10

import Foundation
import PackageDescription

let includeCodeEditSpike = ProcessInfo.processInfo.environment["PROMPTPAD_SPIKE_CODEEDIT"] == "1"

var promptPadAppDependencies: [Target.Dependency] = [
  "PromptPadCore",
  "PromptPadConfig",
  "PromptPadMarkdown",
  "PromptPadTransport",
  "PromptPadProtocol",
  "PromptPadAgent",
]

if includeCodeEditSpike {
  promptPadAppDependencies.append(.product(name: "CodeEditTextView", package: "CodeEditTextView"))
}

let package = Package(
  name: "PromptPad",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(name: "PromptPadProtocol", targets: ["PromptPadProtocol"]),
    .library(name: "PromptPadTransport", targets: ["PromptPadTransport"]),
    .library(name: "PromptPadConfig", targets: ["PromptPadConfig"]),
    .library(name: "PromptPadCore", targets: ["PromptPadCore"]),
    .library(name: "PromptPadMarkdown", targets: ["PromptPadMarkdown"]),
    .library(name: "PromptPadAgent", targets: ["PromptPadAgent"]),
    .executable(name: "promptpad", targets: ["PromptPadCLI"]),
    .executable(name: "promptpad-open", targets: ["PromptPadOpen"]),
    .executable(name: "promptpad-app", targets: ["PromptPadApp"]),
    .executable(name: "promptpad-e2e-harness", targets: ["PromptPadE2EHarness"]),
  ],
  dependencies: includeCodeEditSpike
    ? [
      // Spike candidate text engine for A/B benchmarking.
      .package(url: "https://github.com/CodeEditApp/CodeEditTextView.git", branch: "main"),
    ]
    : [],
  targets: [
    .target(
      name: "PromptPadProtocol"
    ),
    .target(
      name: "PromptPadTransport",
      dependencies: ["PromptPadProtocol"]
    ),
    .target(
      name: "PromptPadConfig"
    ),
    .target(
      name: "PromptPadCore",
      dependencies: ["PromptPadProtocol"]
    ),
    .target(
      name: "PromptPadMarkdown"
    ),
    .target(
      name: "PromptPadAgent",
      dependencies: ["PromptPadCore"]
    ),
    .executableTarget(
      name: "PromptPadCLI",
      dependencies: ["PromptPadConfig", "PromptPadTransport", "PromptPadProtocol", "PromptPadMarkdown"]
    ),
    .executableTarget(
      name: "PromptPadOpen"
    ),
    .executableTarget(
      name: "PromptPadApp",
      dependencies: promptPadAppDependencies
    ),
    .executableTarget(
      name: "PromptPadE2EHarness"
    ),
    .testTarget(
      name: "PromptPadProtocolTests",
      dependencies: ["PromptPadProtocol"]
    ),
    .testTarget(
      name: "PromptPadTransportTests",
      dependencies: ["PromptPadTransport"]
    ),
    .testTarget(
      name: "PromptPadCoreTests",
      dependencies: ["PromptPadCore"]
    ),
    .testTarget(
      name: "PromptPadAgentTests",
      dependencies: ["PromptPadAgent"]
    ),
    .testTarget(
      name: "PromptPadMarkdownTests",
      dependencies: ["PromptPadMarkdown"]
    ),
    .testTarget(
      name: "PromptPadConfigTests",
      dependencies: ["PromptPadConfig"]
    ),
    .testTarget(
      name: "PromptPadIntegrationTests",
      dependencies: ["PromptPadCore", "PromptPadTransport"]
    ),
  ]
)
