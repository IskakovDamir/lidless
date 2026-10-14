#!/bin/bash
# Builds the Windows app (windows/out/Lidless.exe) and runs its unit tests, from macOS or Linux.
# Needs the .NET 8 SDK: https://dotnet.microsoft.com/download (or `brew install --cask dotnet-sdk`).
# Log: build-windows.log next to the repo.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec > >(tee "$ROOT/build-windows.log") 2>&1

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet not found. Install the .NET 8 SDK: brew install --cask dotnet-sdk"
  echo "BUILD FAILED"
  exit 1
fi

echo "== $(date) =="
dotnet --version

OBJ="$HOME/Library/Caches/lidless-windows"
echo; echo "== Unit tests =="
dotnet test "$ROOT/windows/tests/Lidless.Tests.csproj" -c Release \
  --artifacts-path "$OBJ/tests" 2>&1 | tail -15
TESTS=${PIPESTATUS[0]}

echo; echo "== Build Lidless.exe =="
dotnet build "$ROOT/windows/src/Lidless.csproj" -c Release \
  --artifacts-path "$OBJ/app" -o "$ROOT/windows/out" 2>&1 | grep -E "error|warn|Build succeeded|->" | tail -40
BUILD=${PIPESTATUS[0]}

echo
if [[ "$TESTS" == "0" && "$BUILD" == "0" ]]; then
  ls -la "$ROOT/windows/out/Lidless.exe"
  echo "BUILD OK"
else
  echo "BUILD FAILED (tests=$TESTS build=$BUILD)"
  exit 1
fi
