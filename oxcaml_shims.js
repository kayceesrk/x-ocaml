// Shims for OxCaml stdlib primitives that the upstream js_of_ocaml runtime
// doesn't ship. OxCaml's Sys has [external amd64/arm64 : unit -> bool],
// which jsoo lowers to caml_sys_const_arch_<name> runtime calls.

//Provides: caml_sys_const_arch_amd64 const
function caml_sys_const_arch_amd64() {
  return 0;
}

//Provides: caml_sys_const_arch_arm64 const
function caml_sys_const_arch_arm64() {
  return 0;
}
