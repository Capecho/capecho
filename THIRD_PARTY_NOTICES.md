# Third-party notices

Capecho is source-available under the Functional Source License v1.1 (FSL-1.1-Apache-2.0; see [`LICENSE`](LICENSE)). It
incorporates the third-party components below, each under its own license. This
file satisfies the attribution requirements of those licenses.

Most dependencies are pulled at build time by package managers (Flutter/pub for
the Dart clients and shared packages; Bun/npm for the backend) and retain their
own licenses — see each package's `pubspec.yaml` / `package.json` and its
resolved lockfile for the authoritative list. The component below is **vendored**
(its binary is committed to this repository) and therefore is attributed here
directly.

---

## Sparkle

A macOS software-update framework, vendored at
`clients/macos/macos/Frameworks/Sparkle.framework` (version 2.9.2).

- Project: https://sparkle-project.org/
- Source: https://github.com/sparkle-project/Sparkle
- License: MIT (full upstream text, including the complete copyright-holder
  list, at https://github.com/sparkle-project/Sparkle/blob/2.9.2/LICENSE)

```
Copyright (c) 2006 Andy Matuschak and the Sparkle project contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Sparkle also bundles components under additional permissive licenses (e.g. the
BSD-licensed `bsdiff`/`bspatch`); those notices are carried in the upstream
LICENSE linked above.
