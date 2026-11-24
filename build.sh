#!/bin/bash
set -euo pipefail

project="$(cd -- "$(dirname -- "$0")" && pwd)"
build="$project/.build"
bundle="$build/Чубзик.app"
mkdir -p "$build"

if [[ "${1:-}" == "test" ]]; then
    xcrun swiftc -swift-version 5 "$project/Sources/Model.swift" "$project/Sources/CursorChase.swift" "$project/Sources/CompletionNudge.swift" "$project/Sources/ArtworkReader.swift" "$project/Sources/Preferences.swift" "$project/Sources/BrowserVideoPlayback.swift" "$project/Sources/ArDiaVideoPlayback.swift" "$project/Sources/ArDiaAppleEventsPlayback.swift" "$project/Sources/Utilities.swift" "$project/Sources/Events.swift" "$project/Sources/CodexProjectFolder.swift" "$project/Tests/ModelTests.swift" -o "$build/model-tests"
    "$build/model-tests"
    xcrun swiftc -swift-version 5 "$project/Sources/Mascot.swift" "$project/Sources/CompletionNudge.swift" "$project/Tests/MotionTests.swift" -o "$build/motion-tests"
    "$build/motion-tests"
    xcrun swiftc -swift-version 5 "$project/Sources/QuickChatCodex.swift" "$project/Sources/QuickChatInput.swift" "$project/Sources/QuickChatImage.swift" "$project/Tests/QuickChatTests.swift" -o "$build/quick-chat-tests"
    "$build/quick-chat-tests"
    exit
fi

identity_file="$HOME/Library/Application Support/Chubzik/signing-fingerprint"
sign=(codesign --force --sign -)
sign_app=("${sign[@]}")
if [[ "${1:-}" != "--ad-hoc" && -e "$identity_file" ]]; then
    read -r identity < "$identity_file"
    if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf '%s\n' 'Invalid Chubzik signing fingerprint.' >&2
        exit 1
    fi
    keychain=$(security default-keychain -d user | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')
    sign=(codesign --force --sign "$identity" --timestamp=none --keychain "$keychain")
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project/Resources/Info.plist")
    sign_app=("${sign[@]}" "-r=designated => identifier \"$identifier\" and certificate leaf = H\"$identity\"")
fi

mkdir -p "$bundle/Contents/"{MacOS,Resources,Frameworks}
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 "$project"/Sources/*.swift -o "$bundle/Contents/MacOS/Chubzik"
cp "$project/Resources/Info.plist" "$bundle/Contents/"
cp "$project/Resources/"*.icns "$bundle/Contents/Resources/" 2>/dev/null || true
ditto "$project/Resources/На полку.workflow" "$bundle/Contents/Resources/На полку.workflow"

if [[ -d "$project/Resources/MediaRemoteAdapter.framework" ]]; then
    ditto "$project/Resources/MediaRemoteAdapter.framework" "$bundle/Contents/Frameworks/MediaRemoteAdapter.framework"
    cp "$project/Resources/mediaremote-adapter.pl" "$project/Resources/MediaRemoteAdapter-LICENSE.txt" "$bundle/Contents/Resources/"
    "${sign[@]}" "$bundle/Contents/Frameworks/MediaRemoteAdapter.framework"
fi
"${sign_app[@]}" "$bundle"
codesign --verify --deep --strict "$bundle"
printf '%s\n' "$bundle"
