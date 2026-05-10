#!/bin/bash
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
#    --dce builds a single bytecode and runs js_of_ocaml --toplevel-extend
#    --export units.txt so cross-cma DCE runs on the unified IR. Output
#    is a kind=cma bundle that loads cleanly into the existing in-browser
#    toplevel without clobbering its symbol table. Drops bundle size
#    by ~10x compared to the per-cma path.
#
#    Requires the patched js_of_ocaml on PATH (--toplevel-extend flag).
exposed_targets="basement capsule0.expert capsule0.blocking_sync capsule \
                 await.kernel await.sync await.capsule await.blocking await \
                 portable.kernel portable"

# Capsule's curated API uses [open! Base], so its signatures mention
# [Base.unit] (= [Base__.Unit.t] = stdlib unit). The host toplevel
# needs a chain of cmis to expand that alias to a representable type.
# We ship the minimum chain via [--file=src:/static/cmis/]; the .cma
# code stays out of the bundle because base/sexplib0 aren't on the
# bytecode-link line above.
base_dir=$(ocamlfind query base)
sexplib0_dir=$(ocamlfind query sexplib0)
extra_cmis="\
$base_dir/base.cmi \
$base_dir/base__.cmi \
$base_dir/base__Unit.cmi \
$sexplib0_dir/sexplib0.cmi \
$sexplib0_dir/sexplib0__.cmi \
"

workdir=$(mktemp -d)
trap "rm -rf $workdir" EXIT

cat > $workdir/stub.ml <<'OCAML'
let () = ()
OCAML

ocamlfind ocamlc -g -package "$(echo $exposed_targets | tr ' ' ',')" \
  -linkpkg -linkall $workdir/stub.ml -o $workdir/stub.byte

jsoo_listunits -o $workdir/units.txt $exposed_targets

includes=()
for d in $(ocamlfind query -r $exposed_targets); do
  [ -n "$d" ] && includes+=("-I" "$d")
done

file_args=()
for f in $extra_cmis; do
  [ -f "$f" ] && file_args+=("--file=$f:/static/cmis/")
done

js_of_ocaml --toplevel-extend --effects=cps --enable=effect \
  --export $workdir/units.txt "${includes[@]}" "${file_args[@]}" \
  $workdir/stub.byte -o portable_raw.js

# 2. Extract the Stdlib__Modes IIFE from the precompiled stdlib.cma.js.
#    awk on Provides:; print up to but not including the next Provides:.
awk '/^\/\/# unitInfo: Provides: Stdlib__Modes/{p=1}
     p && /^\/\/# unitInfo: Provides:/ && !/Stdlib__Modes/{exit}
     p {print}' "$stdlib_cma_js" > stdlib_modes.js

# 3. Collect every runtime.js shipped by the transitive deps. Capsule /
#    await drag in base, ppx_hash, time_now, etc., each of which ships
#    its own //Provides: stubs (Base_am_testing, Base_int_math_int_pow_stub,
#    base_internalhash_*, time_now, ...). The bundle's IR references these
#    via [globalThis.jsoo_runtime.<name>]; the dynamic property access is
#    invisible to jsoo's static analysis, so we splat each stub onto
#    jsoo_runtime ourselves before the bundle's IIFE runs.
runtime_jss=""
for d in $(ocamlfind query -r \
             basement capsule0.expert capsule0.blocking_sync capsule \
             await.kernel await.sync await.capsule await.blocking await); do
  [ -f "$d/runtime.js" ] && runtime_jss="$runtime_jss $d/runtime.js"
done

# Some prepended runtime.js files [//Requires:] base jsoo runtime
# helpers (caml_hash_mix_int64, caml_int64_lo32, ...) as free
# variables; those live as locals inside the worker's IIFE rather than
# as globals. Bridge the gap by dumping every property of
# [globalThis.jsoo_runtime] onto globalThis as a [var] declaration so
# later top-level code in the prepended runtime.js files can resolve
# them. This has to run before the runtime.js files concatenate in.
{
  echo "(function (globalThis) {"
  echo "  var rt = globalThis.jsoo_runtime;"
  echo "  for (var k in rt) {"
  echo "    if (typeof globalThis[k] === 'undefined') globalThis[k] = rt[k];"
  echo "  }"
  echo "}(globalThis));"
} > runtime_bridge.js

# Build an attach helper that publishes each //Provides: function from
# every transitive runtime.js onto globalThis.jsoo_runtime, so the
# bundle's [r.<name>] property lookups resolve.
{
  echo "(function (globalThis) {"
  echo "  var rt = globalThis.jsoo_runtime;"
  for rt_js in $runtime_jss; do
    grep '^//Provides:' "$rt_js" | sed 's|^//Provides: ||' | \
      awk '{print "  if (typeof " $1 " !== '\''undefined'\'') rt." $1 " = " $1 ";"}'
  done
  echo "}(globalThis));"
} > runtime_attach.js

# 4. Concatenate in load order: Modes registration, every transitive
#    runtime.js (so jsoo_runtime.<name> lookups resolve at load time
#    -- the bundle's IR uses dynamic [globalThis.jsoo_runtime.foo]
#    accesses that bypass jsoo's static link), attach helper, then the
#    raw bundle. The attach helper publishes each //Provides: as a
#    property on jsoo_runtime, since the bundle resolves them via
#    property lookup rather than as free names.
cat stdlib_modes.js runtime_bridge.js $runtime_jss runtime_attach.js portable_raw.js > portable.js

rm -f stdlib_modes.js runtime_bridge.js runtime_attach.js portable_raw.js

ls -lh portable.js
