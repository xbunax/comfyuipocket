#!/bin/bash
set -euo pipefail
# All signing material is injected through Actions secrets and deleted by the cleanup step.
mkdir -p "$RUNNER_TEMP/pocket-signing" "$HOME/Library/MobileDevice/Provisioning Profiles"
python3 - <<'PY'
import os, base64, pathlib
root = pathlib.Path(os.environ['RUNNER_TEMP']) / 'pocket-signing'
for key, name in [('IOS_CERTIFICATE_P12_BASE64','certificate.p12'), ('IOS_PROVISION_PROFILE_BASE64','profile.mobileprovision')]:
    (root / name).write_bytes(base64.b64decode(os.environ[key], validate=True))
PY
keychain="$RUNNER_TEMP/pocket-signing/build.keychain-db"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security import "$RUNNER_TEMP/pocket-signing/certificate.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
security cms -D -i "$RUNNER_TEMP/pocket-signing/profile.mobileprovision" > "$RUNNER_TEMP/pocket-signing/profile.plist"
python3 - <<'PY'
import os, pathlib, plistlib, shutil
root = pathlib.Path(os.environ['RUNNER_TEMP']) / 'pocket-signing'
p = plistlib.loads((root/'profile.plist').read_bytes())
bundle = os.environ.get('IOS_BUNDLE_ID') or 'com.xbunax.comfyuipocket'
team = p['TeamIdentifier'][0]
app_id = p['Entitlements']['application-identifier']
if app_id != f'{team}.{bundle}':
    raise SystemExit(f'Provision profile must match explicit App ID {team}.{bundle}')
shutil.copy(root/'profile.mobileprovision', pathlib.Path.home()/'Library/MobileDevice/Provisioning Profiles'/f'{p["UUID"]}.mobileprovision')
options = {'method': os.environ.get('IOS_EXPORT_METHOD') or 'release-testing', 'teamID': team,
           'signingStyle': 'manual', 'provisioningProfiles': {bundle:p['UUID']},
           'manageAppVersionAndBuildNumber': False}
(root/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
with open(os.environ['GITHUB_ENV'], 'a') as f:
    f.write(f'POCKET_TEAM={team}\nPOCKET_PROFILE={p["UUID"]}\n')
PY
