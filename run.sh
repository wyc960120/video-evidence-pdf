#!/bin/sh
# 零依赖入口：只用 macOS / Xcode 命令行工具自带的 swift
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
exec xcrun swift -swift-version 5 "$DIR/scripts/VideoEvidence.swift" "$@"
