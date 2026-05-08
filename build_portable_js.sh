#!/bin/sh
# Build a portable.js bundle that adds Basement.Portable_atomic to the
# x-ocaml in-browser toplevel. Used by the kcsrk.info OxCaml blog post
# to expose Portable.Atomic without bundling all of base/capsule/etc.
#
# Output: ./portable.js (~860K)
# Load via: <script src-load="/path/to/portable.js"> on the host page.
#
# Why so much shimming?
#   - The basement cma references Stdlib__Modes at runtime; jsoo's
#     toplevel link DCEs Modes from the worker bundle. We prepend the
#     compiled Modes block from stdlib.cma.js.
#   - Basement uses several runtime primitives (basement_dynamic_supported,
#     caml_atomic_*_stub, ...) defined in basement/runtime.js. We append
#     them and an attach helper that re-exports each onto jsoo_runtime.
#   - bin/x_ocaml.exe builds the basement cma + safe_import wrapper.
#
# Run from the x-ocaml repo root:
#   $ dune build && sh build_portable_js.sh
set -eu

cd "$(dirname "$0")"

basement_runtime=$(ocamlfind query basement)/runtime.js
stdlib_cma_js="_build/default/.js/effects=cps+toplevel/stdlib/stdlib.cma.js"

[ -f "$basement_runtime" ] || { echo "missing $basement_runtime — run: opam install basement"; exit 1; }
[ -f "$stdlib_cma_js" ]   || { echo "missing $stdlib_cma_js — run: dune build"; exit 1; }

# 1. Bundle basement (giving Portable.Atomic) plus the lower-level capsule
#    libraries (giving Capsule_expert and Capsule_blocking_sync.Mutex).
#    Both capsule0 sublibraries depend only on basement, so the bundle
#    stays small (~2 MB instead of the ~270 MB the full [portable] +
#    [capsule] dep tree would pull in via base/sexplib0/etc.).
dune exec bin/x_ocaml.exe -- --effects \
  basement capsule0.expert capsule0.blocking_sync -o portable_raw.js >/dev/null

# 2. Extract the Stdlib__Modes IIFE from the precompiled stdlib.cma.js.
#    awk on Provides:; print up to but not including the next Provides:.
awk '/^\/\/# unitInfo: Provides: Stdlib__Modes/{p=1}
     p && /^\/\/# unitInfo: Provides:/ && !/Stdlib__Modes/{exit}
     p {print}' "$stdlib_cma_js" > stdlib_modes.js

# 3. Build an attach helper that re-exports each //Provides: function from
#    basement/runtime.js onto globalThis.jsoo_runtime so the basement cma
#    can reach them via the runtime object.
{
  echo "(function (globalThis) {"
  echo "  var rt = globalThis.jsoo_runtime;"
  grep '^//Provides:' "$basement_runtime" | sed 's|^//Provides: ||' | \
    awk '{print "  if (typeof " $1 " !== '\''undefined'\'') rt." $1 " = " $1 ";"}'
  echo "}(globalThis));"
} > basement_attach.js

# 4. Concatenate in load order: Modes registration, basement runtime
#    primitives, attach helper, then the raw basement cma bundle.
cat stdlib_modes.js "$basement_runtime" basement_attach.js portable_raw.js > portable.js

rm -f stdlib_modes.js basement_attach.js portable_raw.js

ls -lh portable.js
