#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-release}"
output_root="$project_root/dist"
app_bundle="$output_root/DeskBar.app"

cd "$project_root"
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/DeskBar"
if [[ ! -x "$binary_path" ]]; then
  print -u2 "DeskBar executable was not produced at $binary_path"
  exit 1
fi
framework_path="${binary_path:h}/Lottie.framework"
if [[ ! -d "$framework_path" ]]; then
  print -u2 "Lottie framework was not produced at $framework_path"
  exit 1
fi

asset_dir="$project_root/Resources/WhiteDog"
required_assets=(
  cute-white-dog-performing-backflip
  ecstatic-white-dog-celebrating
  happy-white-dog-clapping-hands
  idle-white-dog-character
  sad-white-dog-sitting-alone
  sleepy-white-dog-nodding-off
  thinking-white-dog-with-question-mark-bubbles
)
for asset_name in $required_assets; do
  if [[ ! -f "$asset_dir/$asset_name.json" ]]; then
    print -u2 "Missing local WhiteDog asset: $asset_dir/$asset_name.json"
    print -u2 "Download the licensed IconScout JSON files and place them in Resources/WhiteDog/ before building."
    exit 1
  fi
done

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
cp "$binary_path" "$app_bundle/Contents/MacOS/DeskBar"
cp "$project_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
rm -f "$app_bundle/Contents/Resources/dog-walk.png"
rm -rf "$app_bundle/Contents/Resources/WhiteDog"
ditto "$project_root/Resources/WhiteDog" "$app_bundle/Contents/Resources/WhiteDog"
rm -rf "$app_bundle/Contents/Frameworks/Lottie.framework"
ditto "$framework_path" "$app_bundle/Contents/Frameworks/Lottie.framework"

if ! otool -l "$app_bundle/Contents/MacOS/DeskBar" | grep -Fq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_bundle/Contents/MacOS/DeskBar"
fi

codesign --force --deep --sign - "$app_bundle"
print "$app_bundle"
