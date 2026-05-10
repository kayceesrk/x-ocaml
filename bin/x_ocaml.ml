open Bos

let fatal err =
  Format.printf "ERROR: %s@." err;
  exit 1

let or_fail = function Ok x -> x | Error (`Msg m) -> fatal m
let get_result r = fst @@ or_fail @@ OS.Cmd.out_string r
let lines = String.split_on_char '\n'

let jsoo_safe_import =
  {|(function(globalThis){
  "use strict";
   var runtime = globalThis.jsoo_runtime;
   var register_global = runtime.caml_register_global;
   runtime.caml_register_global = function (a,b,c) {
     if (c !== 'Ast_mapper') {
       return register_global(a,b,c);
     }
   };
   var create_file = runtime.jsoo_create_file;
   runtime.jsoo_create_file = function(a,b) {
     try {
       return create_file(a,b);
     } catch(_err) {
      // console.log('jsoo_create_file', a, err);
     }
   };
}
(globalThis));|}

type t = { name : string; incl : Cmd.t; cma : string; ppx : bool }

let jsoo_compile ~effects t temp_file =
  let toplevel = if t.ppx then Cmd.empty else Cmd.v "--toplevel" in
  let cmd =
    Cmd.(
      v "js_of_ocaml" %% toplevel %% effects %% t.incl % t.cma % "-o"
      % p temp_file)
  in
  let r = get_result @@ OS.Cmd.run_out cmd in
  Format.printf "%s%!" r;
  Result.get_ok @@ Bos.OS.File.read temp_file

let jsoo_export_cma ~effects t =
  or_fail
  @@ Bos.OS.File.with_tmp_output "x-ocaml.%s.js"
       (fun temp_file _ () -> jsoo_compile ~effects t temp_file)
       ()

let ocamlfind_includes lib =
  get_result
  @@ OS.Cmd.run_out
       Cmd.(
         v "ocamlfind" % "query" % lib % "-i-format" % "-predicates" % "byte")

let ocamlfind_cma ~predicate lib =
  get_result
  @@ OS.Cmd.run_out
       Cmd.(
         v "ocamlfind" % "query" % lib % "-a-format" % "-predicates" % predicate)

let ocamlfind_deps ~predicate lib =
  lines @@ get_result
  @@ OS.Cmd.run_out
       Cmd.(
         v "ocamlfind" % "query" % lib % "-r" % "-p-format" % "-predicates"
         % predicate)

module Env = Set.Make (String)

let make ~ppx ~predicate lib =
  let cma = ocamlfind_cma ~predicate lib in
  match lines cma with
  | [] | [ "" ] ->
      Format.printf "skip %s@." lib;
      None
  | [ cma ] ->
      let incl = ocamlfind_includes lib in
      let incl = or_fail @@ Cmd.of_string incl in
      Some { incl; cma; ppx; name = lib }
  | cmas ->
      fatal
        (Format.asprintf "expected one cma for %s, got %i" lib
           (List.length cmas))

let dependencies ~ppx targets env =
  let predicate = if ppx then "ppx_driver,byte" else "byte" in
  let add =
    List.fold_left (fun (env, all) lib ->
        if Env.mem lib env then (env, all)
        else
          let env = Env.add lib env in
          match make ~ppx ~predicate lib with
          | None -> (env, all)
          | Some t -> (env, t :: all))
  in
  let env, selection =
    List.fold_left
      (fun env target ->
        let libs = ocamlfind_deps ~predicate target in
        add env libs)
      (env, []) targets
  in
  (env, List.rev selection)

let output_string output str =
  output (Some (Bytes.of_string str, 0, String.length str))

let main effects targets ppxs output =
  let effects =
    if effects then Cmd.(v "--effects=cps" % "--enable=effect") else Cmd.empty
  in
  let targets =
    match ppxs with
    | [] -> targets
    | _ -> targets @ ppxs @ [ "ppxlib_register" ]
  in
  let env = Env.empty in
  let env, all_ppxs = dependencies ~ppx:true ppxs env in
  let _env, all_libs = dependencies ~ppx:false targets env in
  let all = all_ppxs @ all_libs in
  or_fail @@ or_fail
  @@ (fun f -> f ())
  @@ Bos.OS.File.with_output (Fpath.v output)
  @@ fun output () ->
  let output = output_string output in
  output jsoo_safe_import;
  try
    List.iter
      (fun t ->
        Format.printf "%s@." t.name;
        let js = jsoo_export_cma ~effects t in
        output js)
      all;
    Ok ()
  with _ -> Error (`Msg "export failed")

(* --dce mode: build a single bytecode that links in the requested libraries
   with -linkall, then run
   [js_of_ocaml --toplevel-extend --export units.txt].

   The linker performs cross-cma DCE based on which units are reachable from
   the exports. Output is a [kind=cma] bundle that loads cleanly into an
   existing in-browser toplevel via [src-load], one or two orders of
   magnitude smaller than the per-cma concatenation produced by [main]
   above.

   [--toplevel-extend] is a jsoo flag we added (kc-toplevel-extend branch of
   ocsigen/js_of_ocaml). It emits the [--toplevel --export] bundle as
   non-standalone and skips the [caml_js_set] writes that overwrite the host
   toplevel's [caml_global_data.{symbols,sections,prim_count,aliases}]
   tables, so the host's symbol table and typing environment survive the
   load. Modules from the bundle still register themselves via
   [caml_register_global], which the runtime correctly merges via [symidx].

   Usage:
     x-ocaml --dce --effects basement capsule0.expert capsule0.blocking_sync \
       -o portable.js *)
let main_dce effects targets _ppxs output =
  let effects =
    if effects then Cmd.(v "--effects=cps" % "--enable=effect") else Cmd.empty
  in
  let workdir = Bos.OS.Dir.tmp "x-ocaml-dce-%s" |> or_fail in
  let stub_ml = Fpath.add_seg workdir "stub.ml" in
  let stub_byte = Fpath.add_seg workdir "stub.byte" in
  let units_txt = Fpath.add_seg workdir "units.txt" in
  Bos.OS.File.write stub_ml "let () = ()\n" |> or_fail;

  let pkg = String.concat "," targets in

  (* 1. Bytecode with -linkall to keep every unit reachable. *)
  let _ =
    get_result @@ OS.Cmd.run_out
    @@ Cmd.(
        v "ocamlfind" % "ocamlc"
        % "-package" % pkg
        % "-linkpkg" % "-linkall"
        % p stub_ml % "-o" % p stub_byte)
  in

  (* 2. Export list: the toplevel-visible modules of [targets]. *)
  let _ =
    get_result @@ OS.Cmd.run_out
    @@ Cmd.(
        v "jsoo_listunits" % "-o" % p units_txt %% (of_list targets))
  in

  (* 3. Auto-discover runtime.js files from all transitive deps. *)
  let dep_dirs =
    lines @@ get_result @@ OS.Cmd.run_out
    @@ Cmd.(v "ocamlfind" % "query" % "-r" %% (of_list targets))
  in
  let runtime_jss =
    List.filter_map
      (fun d ->
        let p = Filename.concat d "runtime.js" in
        if Sys.file_exists p then Some p else None)
      dep_dirs
  in

  (* 4. js_of_ocaml --toplevel-extend --export units.txt with all the
        runtime.js files plus the bytecode. --toplevel-extend produces a
        kind=cma bundle that loads cleanly into an existing in-browser
        toplevel without clobbering its symbol table or typing
        environment. *)
  let extra_js = Cmd.of_list runtime_jss in
  let _ =
    get_result @@ OS.Cmd.run_out
    @@ Cmd.(
        v "js_of_ocaml" % "--toplevel-extend" %% effects
        % "--export" % p units_txt
        %% extra_js
        % p stub_byte
        % "-o" % output)
  in
  Format.printf "wrote %s (DCE-bundled)@." output;
  Ok ()

let main_dce_unit effects targets ppxs output =
  match main_dce effects targets ppxs output with
  | Ok () -> ()
  | Error (`Msg m) -> fatal m

open Cmdliner

let arg_output =
  let open Arg in
  required
  & opt (some string) None
  & info [ "o"; "output" ] ~docv:"OUTPUT" ~doc:"Output filename"

let with_effects =
  let open Arg in
  value & flag & info [ "effects" ] ~doc:"Enable effects"

let targets =
  let open Arg in
  non_empty & pos_all string [] & info []

let ppxs =
  let open Arg in
  value & opt_all string [] & info [ "p"; "ppx" ] ~docv:"PPX" ~doc:"PPX"

let with_dce =
  let open Arg in
  value & flag
  & info [ "dce" ]
      ~doc:
        "Cross-cma dead-code elimination: build a single bytecode and run \
         js_of_ocaml --toplevel-extend --export, instead of concatenating \
         per-cma outputs. Yields much smaller bundles (often >10x). Output \
         is a kind=cma artifact that loads cleanly into an existing \
         in-browser toplevel without resetting it. Requires the \
         --toplevel-extend flag from the kc-toplevel-extend branch of \
         js_of_ocaml."

let dispatch dce effects targets ppxs output =
  if dce then main_dce_unit effects targets ppxs output
  else main effects targets ppxs output

let main_term =
  Term.(const dispatch $ with_dce $ with_effects $ targets $ ppxs $ arg_output)
let cmd_main = Cmd.v (Cmd.info "x-ocaml") main_term
let () = exit @@ Cmd.eval cmd_main
