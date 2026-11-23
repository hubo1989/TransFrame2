// swift-tools-version: 6.2
// The dependency edges below are the single source of truth for the layer
// whitelist in SPEC.md §01 §2.1. Scripts/check-deps.sh verifies them.
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]
let mainActorUI: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
]

let domain: Target.Dependency = "TFDomain"
let network: Target.Dependency = "TFNetworkInfra"
let uiBase: [Target.Dependency] = ["TFDomain", "TFDesignSystem", "TFLocalization", "TFWorkspaceUI"]

func feature(_ name: String) -> Target {
    .target(name: name, dependencies: uiBase, swiftSettings: mainActorUI)
}

func infra(_ name: String, _ extra: [Target.Dependency] = [], resources: [Resource]? = nil) -> Target {
    .target(name: name, dependencies: [domain, network] + extra, resources: resources)
}

func tests(_ name: String, _ deps: [Target.Dependency], resources: [Resource]? = nil, ui: Bool = false) -> Target {
    .testTarget(
        name: name,
        dependencies: deps + ["TFDomainTestSupport"],
        resources: resources,
        swiftSettings: ui ? mainActorUI : []
    )
}

let features = [
    "CaptureFeature", "EditorFeature", "PinFeature", "TextTranslationFeature", "HistoryFeature",
    "SettingsFeature", "OnboardingFeature", "MenuBarFeature", "AboutFeature", "ColorFeature",
]

let package = Package(
    name: "TransFrameKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "TransFrameKit",
            targets: [
                "TFDomain", "TFPipelines", "TFNetworkInfra", "TFCaptureInfra", "TFRecognitionInfra",
                "TFTranslationInfra", "TFAIInfra", "TFRenderInfra", "TFPersistenceInfra", "TFSystemInfra",
                "TFUploadInfra", "TFLocalization", "TFDesignSystem", "TFWorkspaceUI",
            ] + features
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/jaywcjlove/PermissionFlow.git", exact: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.7"),
    ],
    targets: [
        // L0
        .target(name: "TFDomain", swiftSettings: strict),
        // L1
        .target(name: "TFPipelines", dependencies: [domain], swiftSettings: strict),
        .target(name: "TFNetworkInfra", dependencies: [domain]),
        infra("TFCaptureInfra"),
        infra("TFRecognitionInfra"),
        infra("TFTranslationInfra"),
        infra("TFAIInfra"),
        infra("TFRenderInfra"),
        infra("TFPersistenceInfra"),
        infra("TFSystemInfra", [
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "PermissionFlow", package: "PermissionFlow"),
        ]),
        infra("TFUploadInfra"),
        .target(name: "TFLocalization", exclude: ["Resources/Localizable.xcstrings"], resources: [.process("Resources")]),
        .target(name: "TFDesignSystem", dependencies: ["TFLocalization"], swiftSettings: mainActorUI),
        // L2
        .target(
            name: "TFWorkspaceUI",
            dependencies: [domain, "TFDesignSystem", "TFLocalization"],
            swiftSettings: mainActorUI
        ),
        // Test support
        .target(name: "TFDomainTestSupport", dependencies: [domain]),

        // Tests
        tests("TFDomainTests", [domain]),
        tests("TFPipelinesTests", [domain, "TFPipelines"]),
        tests("TFNetworkInfraTests", [domain, network]),
        tests("TFTranslationInfraTests", [domain, network, "TFTranslationInfra"]),
        tests("TFRecognitionInfraTests", [domain, network, "TFRecognitionInfra"]),
        tests("TFRenderInfraTests", [domain, "TFRenderInfra"]),
        tests("TFPersistenceInfraTests", [domain, "TFPersistenceInfra"]),
        tests("TFUploadInfraTests", [domain, network, "TFUploadInfra"]),
        tests("TFSystemInfraTests", [domain, "TFSystemInfra"]),
        tests("TFCaptureInfraTests", [domain, "TFCaptureInfra"]),
        tests("TFAIInfraTests", [domain, "TFAIInfra"]),
        tests("TFLocalizationTests", ["TFLocalization"]),
        tests(
            "TFDesignSystemTests",
            ["TFDesignSystem", "TFLocalization", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            ui: true
        ),
        tests("TFWorkspaceUITests", uiBase, ui: true),
        tests("FeatureTests", uiBase + features.map { Target.Dependency(stringLiteral: $0) }, ui: true),
    ] + features.map(feature)
)
