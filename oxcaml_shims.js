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
