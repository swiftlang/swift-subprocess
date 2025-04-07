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

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

let ngroups = getgroups(0, nil)
guard ngroups >= 0 else {
    perror("ngroups should be > 0")
    exit(1)
}
var groups = [gid_t](repeating: 0, count: Int(ngroups))
guard getgroups(ngroups, &groups) >= 0 else {
    perror("getgroups failed")
    exit(errno)
}
let result = groups.map { String($0) }.joined(separator: ",")
print(result)
