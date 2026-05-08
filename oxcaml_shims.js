// Shims for OxCaml stdlib primitives that the upstream js_of_ocaml runtime
// doesn't ship. OxCaml's Sys has [external amd64/arm64 : unit -> bool],
// which jsoo lowers to caml_sys_const_arch_<name> runtime calls. The Sys
// module then refuses to load unless exactly one returns true, so we claim
// arm64 — the JS target is neither, but we have to pick one.

//Provides: caml_sys_const_arch_amd64 const
function caml_sys_const_arch_amd64() {
  return 0;
}

//Provides: caml_sys_const_arch_arm64 const
function caml_sys_const_arch_arm64() {
  return 1;
}

// OxCaml's Domain.TLS0 stores a per-domain state via these primitives.
// JS is single-threaded with a single domain, so a module-level slot is
// enough. caml_domain_tls_get is also called; jsoo lowers OxCaml's
// %tls_get intrinsic to it.

//Provides: caml_oxcaml_domain_tls_state
var caml_oxcaml_domain_tls_state = 0;

//Provides: caml_domain_tls_set
//Requires: caml_oxcaml_domain_tls_state
function caml_domain_tls_set(state) {
  caml_oxcaml_domain_tls_state = state;
  return 0;
}

//Provides: caml_domain_tls_get
//Requires: caml_oxcaml_domain_tls_state
function caml_domain_tls_get() {
  return caml_oxcaml_domain_tls_state;
}

//Provides: caml_domain_spawn
//Requires: caml_domain_dls
//Requires: caml_callback
//Requires: caml_ml_mutex_unlock
//Requires: caml_domain_id
//Version: >= 5.2
var caml_domain_latest_idx = 1;
function caml_domain_spawn(f, term_sync) {
  // Save and restore the global Domain-Local Storage state across spawns.
  // In real multi-domain OCaml each spawned domain has its own DLS; in
  // jsoo's single-threaded runtime the body runs in the same JS context
  // and OxCaml's Domain.spawn body calls DLS.init () which replaces
  // caml_domain_dls with a fresh array. That wipes bindings already
  // stored there by loaded modules -- notably Format.stdbuf_key -- so
  // afterwards Format.flush_str_formatter returns "" because the buffer
  // it reads is a freshly-allocated DLS slot, not the one writes went to.
  var id = caml_domain_latest_idx++;
  var old_id = caml_domain_id;
  var old_dls = caml_domain_dls;
  caml_domain_id = id;
  var res;
  try {
    res = caml_callback(f, [0]);
  } finally {
    caml_domain_id = old_id;
    caml_domain_dls = old_dls;
  }
  // Mark term_sync as Finished (Ok res) and unlock the mutex so join returns.
  // term_sync layout: [0, state, mut, cond]; state Finished payload is Ok res.
  caml_ml_mutex_unlock(term_sync[2]);
  term_sync[1] = [0, [0, res]];
  return id;
}
