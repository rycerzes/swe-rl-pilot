# Issue

**Title:** js.Build: browser:false modules with extensionless require fail with lstat in v0.168.0

## Description

### What version of Hugo are you using (`hugo version`)?

<pre>
$ hugo version
hugo v0.168.0+extended+withdeploy linux/amd64 BuildDate=2026-10-13T16:42:50Z VendorInfo=Homebrew
</pre>

OS/architecture: Linux amd64. Installed with Homebrew.

### Does this issue reproduce with the latest release?

Yes, with v0.168.0, the latest release at the time of reporting.

The same minimal reproduction succeeds with v0.166.0:

```text
hugo v0.166.0-+extended linux/amd64 BuildDate=2026-09-09T14:45:02Z VendorInfo=gohugoio
```

### Summary

`js.Build` fails when a dependency uses an extensionless CommonJS `require` that is disabled by a `browser` field mapping to `false`.

The target `.js` file exists. However, Hugo reports `lstat .../util.inspect: no such file or directory` for the extensionless path instead of allowing esbuild to produce the disabled module stub.

This reproduces without any theme, content, external npm installation, or custom security settings.

### Minimal reproduction

Run the following in an empty directory. The small package under `node_modules` is a synthetic fixture, not an installed dependency.

```sh
mkdir -p assets layouts node_modules/browser-disabled-repro

cat > hugo.toml <<'EOF'
baseURL = "https://example.org/"
disableKinds = ["taxonomy", "term", "rss", "sitemap"]
EOF

cat > layouts/index.html <<'EOF'
{{ $js := resources.Get "main.js" | js.Build }}
<script src="{{ $js.RelPermalink }}"></script>
EOF

cat > assets/main.js <<'EOF'
import value from "browser-disabled-repro";
console.log(value);
EOF

cat > node_modules/browser-disabled-repro/package.json <<'EOF'
{
  "name": "browser-disabled-repro",
  "version": "1.0.0",
  "main": "index.js",
  "browser": {
    "./util.inspect.js": false
  }
}
EOF

cat > node_modules/browser-disabled-repro/index.js <<'EOF'
module.exports = require("./util.inspect");
EOF

cat > node_modules/browser-disabled-repro/util.inspect.js <<'EOF'
module.exports = "This file must be excluded from browser builds.";
EOF

hugo --noBuildLock
```

### Actual result

On v0.168.0 the build exits with code 1. Relevant error excerpt (absolute project path normalized):

```text
error calling RelPermalink: JSBUILD: failed to transform "/main.js" (text/javascript): lstat /path/to/repro/node_modules/browser-disabled-repro/util.inspect: no such file or directory
```

### Expected result

The build should succeed, with the dependency replaced by an empty browser module according to `browser: { "./util.inspect.js": false }`, without including the excluded file's content.

### Comparison and control

| Configuration | Result |
| --- | --- |
| v0.166.0, `require("./util.inspect")` | Build succeeds, exit 0 |
| v0.168.0, `require("./util.inspect")` | Build fails with the `lstat` error, exit 1 |
| v0.168.0, changing only the require to `require("./util.inspect.js")` | Build succeeds, exit 0 |

The v0.166.0 output explicitly contains a disabled-module stub:

```js
// (disabled):node_modules/browser-disabled-repro/util.inspect
var require_util = __commonJS({
  "(disabled):node_modules/browser-disabled-repro/util.inspect"() {
  }
});
```

The explicit-extension control is only diagnostic; it is not a proposed fix for third-party dependencies.

### Possibly related change

 adds an `OnLoad` hook in the `file` namespace that calls `CheckReadPath(args.Path)`. `CheckReadPath` uses `filepath.EvalSymlinks`, which requires the path to exist.

The failure appears consistent with that hook checking esbuild's disabled-module path as though it were a file to load. This is a suspected explanation, not a bisected root cause; v0.167.0 and current master have not been tested.

The original occurrence was through `instantsearch.js -> qs -> side-channel -> object-inspect@1.13.4`. That package uses `require('./util.inspect')` and maps `"./util.inspect.js"` to `false` in its `browser` field.

I searched open and closed issues and pull requests for `util.inspect`, `object-inspect`, `CheckReadPath`, and related browser-disabled/esbuild er

…(truncated)

## Task

Modify the repository so that the issue described above is resolved. The task's test suite verifies your patch by applying it on top of the base commit `ed22b85c192d` and running the modified tests.