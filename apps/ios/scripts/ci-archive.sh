#!/bin/bash
set -euo pipefail
# Signing material lives only in a temporary directory and is never uploaded.
: "${IOS_CERTIFICATE_P12_BASE64:?Set IOS_CERTIFICATE_P12_BASE64}"
: "${IOS_PROFILE_BASE64:?Set IOS_PROFILE_BASE64}"
: "${IOS_CERTIFICATE_PASSWORD?Set IOS_CERTIFICATE_PASSWORD (may be empty)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
DIST="$REPO_ROOT/dist/ios"
cd "$ROOT"
SIGNING_DIR="$(mktemp -d)"
KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
PROFILE_PATH=""
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  if [[ -n "$PROFILE_PATH" ]]; then rm -f "$PROFILE_PATH"; fi
  rm -rf "$SIGNING_DIR"
}
trap cleanup EXIT
export SIGNING_DIR
python3 - <<'PY'
import base64, os
from pathlib import Path
p=Path(os.environ['SIGNING_DIR'])
for env, name in [('IOS_CERTIFICATE_P12_BASE64','certificate.p12'),('IOS_PROFILE_BASE64','profile.mobileprovision')]:
    p.joinpath(name).write_bytes(base64.b64decode(''.join(os.environ[env].split()),validate=True))
PY
security cms -D -i "$SIGNING_DIR/profile.mobileprovision" > "$SIGNING_DIR/profile.plist"
python3 - <<'PY'
import datetime, os, plistlib
from pathlib import Path
p=Path(os.environ['SIGNING_DIR'])
v=plistlib.loads(p.joinpath('profile.plist').read_bytes()); e=v['Entitlements']
assert v['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Provisioning profile expired'
assert v.get('ProvisionedDevices'), 'Use a Development or Ad Hoc profile containing your iPhone'
team=v['TeamIdentifier'][0]
assert e.get('application-identifier') == team+'.me.stackli.hako', 'Profile must be for me.stackli.hako'
for key in ['com.apple.developer.family-controls','com.apple.developer.family-controls.app-and-website-usage']:
    assert e.get(key) is True, 'Missing entitlement: '+key
method='debugging' if e.get('get-task-allow') else 'release-testing'
for name,value in [('team',team),('uuid',v['UUID'])]: p.joinpath(name).write_text(value)
options={'method':method,'teamID':team,'signingStyle':'manual','provisioningProfiles':{'me.stackli.hako':v['UUID']},'manageAppVersionAndBuildNumber':False}
p.joinpath('ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
TEAM="$(cat "$SIGNING_DIR/team")"
PROFILE_UUID="$(cat "$SIGNING_DIR/uuid")"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$SIGNING_DIR/certificate.p12" -k "$KEYCHAIN" -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"/ {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo 'No valid signing identity in P12'; exit 1; }
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
PROFILE_PATH="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
cp "$SIGNING_DIR/profile.mobileprovision" "$PROFILE_PATH"
xcodebuild -version
mkdir -p build/ci "$DIST"
# SwiftTerm's build-tool plugin generates its version information. The package
# is pinned to an exact version in the project; CI has no interactive trust UI.
# HAKO_SIGN_* is consumed only by the app target. Global signing overrides
# would also apply the iOS provisioning profile to SwiftPM's macOS build tools.
xcodebuild -skipPackagePluginValidation -project Hako.xcodeproj -scheme Hako -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/ci/Hako.xcarchive -derivedDataPath build/ci/DerivedData \
  HAKO_SIGN_STYLE=Manual HAKO_SIGN_TEAM="$TEAM" HAKO_SIGN_IDENTITY="$IDENTITY" \
  HAKO_SIGN_PROFILE="$PROFILE_UUID" HAKO_SIGN_FLAGS="--keychain $KEYCHAIN" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" archive
xcodebuild -exportArchive -archivePath build/ci/Hako.xcarchive \
  -exportPath "$DIST" -exportOptionsPlist "$SIGNING_DIR/ExportOptions.plist"
