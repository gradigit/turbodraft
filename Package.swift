// swift-tools-version: 5.10

import Foundation
import PackageDescription

let includeCodeEditSpike = ProcessInfo.processInfo.environment["TURBODRAFT_SPIKE_CODEEDIT"] == "1"

var turboDraftAppDependencies: [Target.Dependency] = [
  "TurboDraftCore",
  "TurboDraftConfig",
  "TurboDraftMarkdown",
  "TurboDraftTransport",
  "TurboDraftProtocol",
  "TurboDraftAgent",
]

if includeCodeEditSpike {
  turboDraftAppDependencies.append(.product(name: "CodeEditTextView", package: "CodeEditTextView"))
}

let package = Package(
  name: "TurboDraft",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(name: "TurboDraftProtocol", targets: ["TurboDraftProtocol"]),
    .library(name: "TurboDraftTransport", targets: ["TurboDraftTransport"]),
    .library(name: "TurboDraftConfig", targets: ["TurboDraftConfig"]),
    .library(name: "TurboDraftCore", targets: ["TurboDraftCore"]),
    .library(name: "TurboDraftMarkdown", targets: ["TurboDraftMarkdown"]),
    .library(name: "TurboDraftAgent", targets: ["TurboDraftAgent"]),
    .executable(name: "turbodraft-bench", targets: ["TurboDraftCLI"]),
    .executable(name: "turbodraft", targets: ["TurboDraftOpen"]),
    .executable(name: "turbodraft-app", targets: ["TurboDraftApp"]),
    .executable(name: "turbodraft-e2e-harness", targets: ["TurboDraftE2EHarness"]),
  ],
  dependencies: includeCodeEditSpike
    ? [
      // Spike candidate text engine for A/B benchmarking. Uses branch: "main"
      // because this is env-gated (TURBODRAFT_SPIKE_CODEEDIT=1) and not shipped (#42).
      .package(url: "https://github.com/CodeEditApp/CodeEditTextView.git", branch: "main"),
    ]
    : [],
  targets: [
    .target(
      name: "TurboDraftProtocol"
    ),
    .target(
      name: "TurboDraftTransport",
      dependencies: ["TurboDraftProtocol"]
    ),
    .target(
      name: "TurboDraftConfig"
    ),
    .target(
      name: "TurboDraftCore",
      dependencies: ["TurboDraftProtocol"]
    ),
    .target(
      name: "TurboDraftMarkdown"
    ),
    .target(
      name: "TurboDraftAgent",
      dependencies: ["TurboDraftCore"]
    ),
    .executableTarget(
      name: "TurboDraftCLI",
      dependencies: ["TurboDraftConfig", "TurboDraftTransport", "TurboDraftProtocol", "TurboDraftMarkdown"]
    ),
    .executableTarget(
      name: "TurboDraftOpen"
    ),
    .executableTarget(
      name: "TurboDraftApp",
      dependencies: turboDraftAppDependencies
    ),
    .executableTarget(
      name: "TurboDraftE2EHarness"
    ),
    .testTarget(
      name: "TurboDraftProtocolTests",
      dependencies: ["TurboDraftProtocol"]
    ),
    .testTarget(
      name: "TurboDraftTransportTests",
      dependencies: ["TurboDraftTransport"]
    ),
    .testTarget(
      name: "TurboDraftCoreTests",
      dependencies: ["TurboDraftCore"]
    ),
    .testTarget(
      name: "TurboDraftAgentTests",
      dependencies: ["TurboDraftAgent"]
    ),
    .testTarget(
      name: "TurboDraftMarkdownTests",
      dependencies: ["TurboDraftMarkdown"]
    ),
    .testTarget(
      name: "TurboDraftConfigTests",
      dependencies: ["TurboDraftConfig"]
    ),
    .testTarget(
      name: "TurboDraftIntegrationTests",
      dependencies: ["TurboDraftCore", "TurboDraftTransport"]
    ),
  ]
)
