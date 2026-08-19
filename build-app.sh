#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")"
release_mode="${POMOSENTRY_RELEASE_MODE:-development}"
signing_identity="${POMOSENTRY_SIGN_IDENTITY:-}"
entitlements="$project_dir/PomoSentry.entitlements"
app_dir="$project_dir/PomoSentry.app"
artifact_suffix="$version-universal"

if [[ "$release_mode" != "development" && "$release_mode" != "public" ]]; then
    echo "POMOSENTRY_RELEASE_MODE must be development or public" >&2
    exit 64
fi

if [[ "$release_mode" == "public" && -z "$signing_identity" ]]; then
    echo "Public release refused: set POMOSENTRY_SIGN_IDENTITY to a Developer ID Application certificate." >&2
    exit 65
fi

staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/PomoSentryBuild.XXXXXX")"
cleanup() { /bin/rm -rf "$staging_dir"; }
trap cleanup EXIT HUP INT TERM

swift package clean
swift test
swift build -c release --arch arm64
arm_bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"
swift build -c release --arch x86_64
x64_bin_dir="$(swift build -c release --arch x86_64 --show-bin-path)"

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/usr/bin/lipo -create "$arm_bin_dir/FanqieZhong" "$x64_bin_dir/FanqieZhong" -output "$app_dir/Contents/MacOS/FanqieZhong"
/usr/bin/lipo "$app_dir/Contents/MacOS/FanqieZhong" -verify_arch arm64 x86_64
/bin/chmod +x "$app_dir/Contents/MacOS/FanqieZhong"
/bin/cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
/bin/cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "$project_dir/Resources/en.lproj" "$app_dir/Contents/Resources/en.lproj"
/usr/bin/ditto "$project_dir/Resources/zh-Hans.lproj" "$app_dir/Contents/Resources/zh-Hans.lproj"

if [[ "$release_mode" == "public" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$signing_identity" "$app_dir"
else
    /usr/bin/codesign --force --sign - "$app_dir"
fi
/usr/bin/codesign --verify --strict --verbose=4 "$app_dir"

notarize() {
    local artifact="$1"
    if [[ -n "${POMOSENTRY_NOTARY_PROFILE:-}" ]]; then
        /usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$POMOSENTRY_NOTARY_PROFILE" --wait
    else
        : "${POMOSENTRY_APPLE_ID:?Set POMOSENTRY_APPLE_ID or POMOSENTRY_NOTARY_PROFILE}"
        : "${POMOSENTRY_TEAM_ID:?Set POMOSENTRY_TEAM_ID or POMOSENTRY_NOTARY_PROFILE}"
        : "${POMOSENTRY_APP_PASSWORD:?Set POMOSENTRY_APP_PASSWORD or POMOSENTRY_NOTARY_PROFILE}"
        /usr/bin/xcrun notarytool submit "$artifact" --apple-id "$POMOSENTRY_APPLE_ID" --team-id "$POMOSENTRY_TEAM_ID" --password "$POMOSENTRY_APP_PASSWORD" --wait
    fi
}

if [[ "$release_mode" == "public" ]]; then
    preflight_zip="$staging_dir/PomoSentry-notarization.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$preflight_zip"
    notarize "$preflight_zip"
    /usr/bin/xcrun stapler staple "$app_dir"
    /usr/bin/xcrun stapler validate "$app_dir"
fi

if [[ "$release_mode" == "public" ]]; then
    dmg_path="$project_dir/PomoSentry-$artifact_suffix.dmg"
    zip_path="$project_dir/PomoSentry-$artifact_suffix.zip"
else
    dmg_path="$project_dir/PomoSentry-$artifact_suffix-development.dmg"
    zip_path="$project_dir/PomoSentry-$artifact_suffix-development.zip"
fi
/bin/rm -f "$dmg_path" "$zip_path"
/bin/mkdir -p "$staging_dir/dmg"
/usr/bin/ditto "$app_dir" "$staging_dir/dmg/PomoSentry.app"
/bin/ln -s /Applications "$staging_dir/dmg/Applications"
/usr/sbin/diskutil image create from --format UDZO --volumeName "PomoSentry" "$staging_dir/dmg" "$dmg_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"

if [[ "$release_mode" == "public" ]]; then
    notarize "$dmg_path"
    /usr/bin/xcrun stapler staple "$dmg_path"
    /usr/bin/xcrun stapler validate "$dmg_path"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$app_dir"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
fi

/usr/bin/shasum -a 256 "$dmg_path" "$zip_path" > "$project_dir/PomoSentry-$artifact_suffix-SHA256.txt"
echo "Built mode: $release_mode"
echo "Built $app_dir"
echo "Built $dmg_path"
echo "Built $zip_path"
