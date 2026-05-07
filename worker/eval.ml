open Js_of_ocaml_toplevel
open X_protocol

(* Force jsoo to link Stdlib__Modes. Without this, dead-code elimination
   strips Modes from the toplevel bundle, and any library (such as
   Basement) that references Stdlib__Modes at runtime fails to load. *)
let force_modes_link : unit ref = ref ()
let () =
  force_modes_link := (Modes.Portable.{ portable = () }).portable;
  force_modes_link := (Modes.Contended.{ contended = () }).contended;
  force_modes_link := (Modes.Aliased.{ aliased = () }).aliased;
  force_modes_link := (Modes.Shared.{ shared = () }).shared;
  force_modes_link := (Modes.Many.{ many = () }).many;
  force_modes_link := (Modes.Global.{ global = () }).global;
  force_modes_link := (Modes.Portended.{ portended = () }).portended;
  force_modes_link := (Modes.Unyielding.{ unyielding = () }).unyielding;
  Printf.printf "%!" (* prevent inlining away *)

(* Enable the alpha extension universe so user code in the toplevel can
   use kind annotations like [: value mod contended portable]. Without
   this, those annotations parse silently but don't take effect. *)
let () = Language_extension.set_universe_and_enable_all_of_string_exn "alpha"

let environments = ref []

let setup_toplevel () =
  let _ = JsooTop.initialize () in
  Sys.interactive := false;
  environments := [ (0, !Toploop.toplevel_env) ]

let reset id =
  let rec go id = function
    | [] -> failwith ("no environment " ^ string_of_int id)
    | [ (_, x) ] as rest ->
        Toploop.toplevel_env := x;
        rest
    | (id', _) :: xs when id' >= id -> go id xs
    | x :: xs ->
        Toploop.toplevel_env := snd x;
        x :: xs
  in
  environments := go id !environments

let rec parse_use_file ~caml_ppf lex =
  let _at = lex.Lexing.lex_curr_pos in
  match !Toploop.parse_toplevel_phrase lex with
  | ok -> ok :: parse_use_file ~caml_ppf lex
  | exception End_of_file -> []
  | exception err ->
      Errors.report_error caml_ppf err;
      []

let ppx_rewriters = ref []

let preprocess_structure str =
  let open Ast_mapper in
  List.fold_right
    (fun ppx_rewriter str ->
      let mapper = ppx_rewriter [] in
      mapper.structure mapper str)
    !ppx_rewriters str

let preprocess_phrase phrase =
  let open Parsetree in
  match phrase with
  | Ptop_def str -> Ptop_def (preprocess_structure str)
  | Ptop_dir _ as x -> x

let execute ~id ~output code_text =
  reset id;
  let outputs = ref [] in
  let buf = Buffer.create 64 in
  let caml_ppf = Format.formatter_of_buffer buf in
  let content = code_text ^ " ;;" in
  let phrases = parse_use_file ~caml_ppf (Lexing.from_string content) in
  Js_of_ocaml.Sys_js.set_channel_flusher stdout (fun str ->
      outputs := Stdout str :: !outputs);
  Js_of_ocaml.Sys_js.set_channel_flusher stderr (fun str ->
      outputs := Stderr str :: !outputs);
  let get_out () =
    Format.pp_print_flush caml_ppf ();
    let meta = Buffer.contents buf in
    Buffer.clear buf;
    let out = if meta = "" then !outputs else Meta meta :: !outputs in
    outputs := [];
    List.rev out
  in
  let respond ~(at_loc : Location.t) =
    let loc = at_loc.loc_end.pos_cnum in
    let out = get_out () in
    output ~loc out
  in
  List.iter
    (fun phrase ->
      let sub_phrases =
        match phrase with
        | Parsetree.Ptop_def s -> List.map (fun s -> Parsetree.Ptop_def [ s ]) s
        | Ptop_dir _ -> [ phrase ]
      in
      List.iter
        (fun phrase ->
          let at_loc =
            match phrase with
            | Parsetree.Ptop_def ({ pstr_loc = loc; _ } :: _) -> loc
            | Ptop_dir { pdir_loc = loc; _ } -> loc
            | _ -> assert false
          in
          try
            Location.reset ();
            let phrase = preprocess_phrase phrase in
            let _r = Toploop.execute_phrase true caml_ppf phrase in
            respond ~at_loc
          with _exn ->
            Errors.report_error caml_ppf _exn;
            respond ~at_loc)
        sub_phrases)
    phrases;
  environments := (id, !Toploop.toplevel_env) :: !environments;
  get_out ()

let () =
  Ast_mapper.register_function :=
    fun _ f -> ppx_rewriters := f :: !ppx_rewriters
