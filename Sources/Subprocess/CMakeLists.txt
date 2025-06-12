target_sources(Subprocess PRIVATE
  Execution.swift
  Buffer.swift
  Error.swift
  Teardown.swift
  Result.swift
  IO/Output.swift
  IO/Input.swift
  Span+Subprocess.swift
  AsyncBufferSequence.swift
  API.swift
  SubprocessFoundation/Span+SubprocessFoundation.swift
  SubprocessFoundation/Output+Foundation.swift
  SubprocessFoundation/Input+Foundation.swift
  Configuration.swift)

if(WIN32)
  target_sources(Subprocess PRIVATE Platforms/Subprocess+Windows.swift)
elseif(LINUX OR ANDROID)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+Linux.swift
    Platforms/Subprocess+Unix.swift)
elseif(APPLE)
  target_sources(Subprocess PRIVATE
    Platforms/Subprocess+Darwin.swift
    Platforms/Subprocess+Unix.swift)
endif()
