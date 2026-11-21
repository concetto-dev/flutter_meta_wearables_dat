#!/bin/bash
# CONCETTO FORK (simulated glasses): copies Meta's MWDATMockDevice into a
# DEBUG build of the app, signed, so SimulatedGlasses.swift can load it.
#
# Run it as a Run Script build phase of the app target, after "Embed
# Frameworks" and after the CocoaPods phases:
#
#   bash "${PODS_ROOT}/../.symlinks/plugins/flutter_meta_wearables_dat/ios/flutter_meta_wearables_dat/MockDevice/embed-mock-device.sh"
#
# It does nothing for any configuration whose name does not start with
# "Debug", so a Release or Profile build (TestFlight, production) never
# carries the framework. Nothing links it; the app loads it with dlopen.
set -euo pipefail

case "${CONFIGURATION:-}" in
  Debug*) ;;
  *)
    echo "embed-mock-device: ${CONFIGURATION:-?} is not a Debug configuration; nothing embedded"
    exit 0
    ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
xcframework="${here}/MWDATMockDevice.xcframework"

case "${PLATFORM_NAME:-}" in
  iphonesimulator) slice="ios-arm64_x86_64-simulator" ;;
  iphoneos) slice="ios-arm64" ;;
  *)
    echo "embed-mock-device: platform ${PLATFORM_NAME:-?} has no slice; nothing embedded"
    exit 0
    ;;
esac

source_framework="${xcframework}/${slice}/MWDATMockDevice.framework"
if [ ! -d "${source_framework}" ]; then
  echo "error: embed-mock-device: ${source_framework} is missing" >&2
  exit 1
fi

dest_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${dest_dir}"
rm -rf "${dest_dir}/MWDATMockDevice.framework"
cp -R "${source_framework}" "${dest_dir}/"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --preserve-metadata=identifier,entitlements \
    "${dest_dir}/MWDATMockDevice.framework"
fi

echo "embed-mock-device: embedded the ${slice} slice for ${CONFIGURATION}"
