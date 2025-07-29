//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#if canImport(WinSDK)
@preconcurrency import WinSDK
#endif

// Confitionally require Foundation due to `Bundle.module`
import Foundation

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

package var prideAndPrejudice: FilePath {
    let path = Bundle.module.url(
        forResource: "PrideAndPrejudice",
        withExtension: "txt",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

package var theMysteriousIsland: FilePath {
    let path = Bundle.module.url(
        forResource: "TheMysteriousIsland",
        withExtension: "txt",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

package var getgroupsSwift: FilePath {
    let path = Bundle.module.url(
        forResource: "getgroups",
        withExtension: "swift",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

package var windowsTester: FilePath {
    let path = Bundle.module.url(
        forResource: "windows-tester",
        withExtension: "ps1",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

extension URL {
    package var _fileSystemPath: String {
        #if canImport(WinSDK)
        var path = self.path(percentEncoded: false)
        if path.starts(with: "/") {
            path.removeFirst()
            return path
        }
        return path
        #else
        return self.path(percentEncoded: false)
        #endif
    }
}
