// swift-tools-version: 5.10
import PackageDescription

// Everything that is not screen code lives here, split so that each layer can
// only see what it is allowed to depend on:
//
//   CoupleDomain        models, rules, validation, repository protocols. No I/O.
//   CoupleDesign        design tokens and reusable SwiftUI components.
//   CoupleWidgetUI      the widget snapshot store and widget views, shared by
//                       the widget extension and the app's own previews.
//   CoupleLocalBackend  in-memory implementation of the repositories, used by
//                       tests, previews and the DEBUG-only demo mode.
//   CoupleSupabase      the production implementation, on supabase-swift.
let package = Package(
    name: "CoupleKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoupleDomain", targets: ["CoupleDomain"]),
        .library(name: "CoupleDesign", targets: ["CoupleDesign"]),
        .library(name: "CoupleWidgetUI", targets: ["CoupleWidgetUI"]),
        .library(name: "CoupleLocalBackend", targets: ["CoupleLocalBackend"]),
        .library(name: "CoupleSupabase", targets: ["CoupleSupabase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0"),
    ],
    targets: [
        .target(name: "CoupleDomain"),
        .target(name: "CoupleDesign", dependencies: ["CoupleDomain"]),
        .target(name: "CoupleWidgetUI", dependencies: ["CoupleDomain", "CoupleDesign"]),
        .target(name: "CoupleLocalBackend", dependencies: ["CoupleDomain"]),
        .target(
            name: "CoupleSupabase",
            dependencies: [
                "CoupleDomain",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "CoupleDomainTests", dependencies: ["CoupleDomain"]),
        .testTarget(name: "CoupleWidgetUITests", dependencies: ["CoupleDomain", "CoupleWidgetUI"]),
        // Talks to a real Supabase project. Skipped unless SUPABASE_HOST and
        // SUPABASE_KEY are set in the environment; see TESTING.md.
        .testTarget(name: "CoupleSupabaseLiveTests", dependencies: ["CoupleDomain", "CoupleSupabase"]),
        .testTarget(
            name: "CoupleLocalBackendTests",
            dependencies: ["CoupleDomain", "CoupleLocalBackend"]
        ),
    ]
)
