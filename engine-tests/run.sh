#!/bin/sh
# Ba-Chan memory-engine acceptance harness (SPEC §9).
# Compiles the REAL engine sources + the harness with swiftc on the host (macOS,
# where Apple's NaturalLanguage framework is available) and runs them. No Xcode,
# no device, no LLM — this validates the deterministic memory engine.
set -e
cd "$(dirname "$0")"

ENGINE="../BaChan/Memory/MemoryRecord.swift \
        ../BaChan/Memory/MemoryConfig.swift \
        ../BaChan/Memory/Lucidity.swift \
        ../BaChan/Memory/PersonaProfile.swift \
        ../BaChan/Memory/PersonaLearner.swift \
        ../BaChan/Face/Expression.swift \
        ../BaChan/Brain/BrainContext.swift \
        ../BaChan/Brain/Brain.swift \
        ../BaChan/Brain/FoundationGuard.swift \
        ../BaChan/Brain/ChatArtifacts.swift \
        ../BaChan/Brain/LookIntent.swift \
        ../BaChan/Memory/MemoryStore.swift"

swiftc -O $ENGINE main.swift -o .harness
./.harness
