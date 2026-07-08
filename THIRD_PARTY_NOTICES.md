# Third-Party Notices

Millie is built on top of, and redistributes parts of, the following
third-party software. Each component remains under its own license.

## Chromium & ungoogled-chromium

Millie is a patched build of [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium)
(via [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos)),
which is itself derived from [Chromium](https://www.chromium.org/).
`chromium-tree.patch` and the `mori_*` bridge sources in `overlay/` are
derivative works of the Chromium source tree.

Chromium is licensed under the BSD 3-Clause License, © The Chromium
Authors. The full set of licenses for Chromium and its bundled
dependencies is available at `chrome://credits` in any build.

ungoogled-chromium is licensed as follows:

```
Copyright 2023 The ungoogled-chromium Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above
  copyright notice, this list of conditions and the following disclaimer
  in the documentation and/or other materials provided with the
  distribution.
* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Sparkle

`Sparkle.framework` (auto-update) is redistributed unmodified from the
[Sparkle project](https://github.com/sparkle-project/Sparkle), which is
available under the MIT License (with some bundled components under
their own permissive licenses). The complete license text is in the
Sparkle repository's
[LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)
file. © Andy Matuschak and the Sparkle Project contributors.

## Google Sans

The typefaces in `fonts/` are distributed under the SIL Open Font
License 1.1 — see [fonts/OFL.txt](fonts/OFL.txt).

## Widevine CDM

Widevine is a proprietary content-decryption module licensed by Google.
It is **not** part of this repository and is not redistributable here;
release builds stage it locally under `widevine/` (gitignored) at
package time.
