#!/usr/bin/env bash
# Fast path: relink Chromium Framework from existing objects (ninja's deps log is unreliable here)
set -euo pipefail
cd ~/mori-browser-build/build/src/out/Default
export PATH="$HOME/mori-browser-build/buildpy/bin:/opt/homebrew/bin:$PATH" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VPYTHON_BYPASS=x
# Xcode updates delete the root-owned MacOSX26.0.sdk link; fall back to the CLT copy
# (same SDK, no arm64e.x1 TAPI tokens). Fine for compile/link-only runs.
mkdir -p sdk/xcode_links
XSDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk
[ -e "$XSDK" ] || XSDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk
ln -sfn "$XSDK" sdk/xcode_links/MacOSX26.0.sdk
# Recompile the Swift overlay first (command regenerated each run; fail loudly).
rsync -a ~/mori-browser-build/millie/overlay/ ../../chrome/browser/ui/mori/
ninja -t commands -s obj/chrome/browser/ui/mori_ui_swift/chrome_browser_ui_mori_ui_swift.swiftmodule > ~/mori-browser-build/swift154.cmd
[ -s ~/mori-browser-build/swift154.cmd ] || { echo "FATAL: no swift compile command"; exit 1; }
bash ~/mori-browser-build/swift154.cmd > ~/mori-browser-build/swift154.log 2>&1 || { echo "FATAL: swift compile failed"; grep -E "error" ~/mori-browser-build/swift154.log | head; exit 1; }
python3 - <<'PY'
import re,shlex
lines=open('obj/chrome/chrome_framework_shared_library.ninja').read().split('\n')
i=next(k for k,l in enumerate(lines) if l.startswith('build obj/chrome/chrome_framework_shared_library/Chromium$ Framework '))
head=lines[i]; vars_={}; j=i+1
while j<len(lines) and lines[j].startswith('  '):
    k,_,v=lines[j].strip().partition(' = '); vars_[k]=v; j+=1
m=re.match(r'build (.*?): (\w+) (.*)',head); ins=re.split(r' \|\| | \| ',m.group(3))[0]
inp=[t.replace('$ ',' ').replace('$:',':').replace('$$','$') for t in re.split(r'(?<!\$) ',ins) if t]
q=lambda t: shlex.quote(t) if re.search(r'[^\w@%+=:,./-]',t) else t
open('obj/chrome/chrome_framework_shared_library/Chromium Framework.rsp','w').write(' '.join(q(t) for t in inp)+' '+' '.join(vars_.get(k,'') for k in ('frameworks','swiftmodules','solibs','libs'))+'\n')
PY
ninja -t commands -s "obj/chrome/chrome_framework_shared_library/Chromium Framework" > /tmp/link154.cmd
bash /tmp/link154.cmd
cp "obj/chrome/chrome_framework_shared_library/Chromium Framework" "Chromium.app/Contents/Frameworks/Chromium Framework.framework/Versions/154.0.8037.97/Chromium Framework"
cd ~/mori-browser-build && MILLIE_APP=$PWD/Millie-vanilla154.app bash millie/package_mori.sh | tail -2
