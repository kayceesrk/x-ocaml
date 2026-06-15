open Brr

type status = Not_run | Running | Run_ok | Request_run

type t = {
  id : int;
  mutable prev : t option;
  mutable next : t option;
  mutable status : status;
  mutable errored : bool;
      (* Did this cell's last run produce a compile/type error? Such a
         cell is excluded from [pre_source] below, so a deliberate
         "this is rejected" demo does not poison merlin's typing (and
         thus type-on-hover and lint) for every later cell. *)
  cm : Editor.t;
  worker : Client.t;
  merlin_worker : Merlin_ext.Client.worker;
  run_on : [ `Click | `Load ];
}

let id t = t.id

(* The toplevel renders compile/type errors via [Errors.report_error],
   which always prints "Error:"; a successful [val]/[type]/[module]
   echo never contains that exact token. *)
let contains_substring hay needle =
  let lh = String.length hay and ln = String.length needle in
  if ln = 0 then true
  else
    let rec go i =
      if i + ln > lh then false
      else if String.sub hay i ln = needle then true
      else go (i + 1)
    in
    go 0

let output_has_error (msg : X_protocol.output list) =
  List.exists
    (fun o ->
      let s =
        match (o : X_protocol.output) with
        | Stdout s | Stderr s | Meta s | Html s -> s
      in
      contains_substring s "Error:")
    msg

(* The source of every cell before [t] in chain order, used as the
   prefix of merlin's buffer so queries on [t] see the cumulative
   context. The accumulator is already in chain (document) order when
   the head is reached: do not reverse it. *)
let pre_source t =
  let rec go acc t =
    match t.prev with
    | None -> String.concat "\n" acc
    | Some e ->
        (* Skip cells whose last run errored: their source would make
           merlin fail to type every later cell's cumulative buffer. *)
        let acc = if e.errored then acc else Editor.source e.cm :: acc in
        go acc e
  in
  let s = go [] t in
  if s = "" then s else s ^ " ;;\n"

let rec invalidate_from ~editor =
  editor.status <- Not_run;
  Editor.clear editor.cm;
  let count = Editor.nb_lines editor.cm in
  match editor.next with
  | None -> ()
  | Some editor ->
      Editor.set_previous_lines editor.cm count;
      invalidate_from ~editor

let invalidate_after ~editor =
  editor.status <- Not_run;
  let count = Editor.nb_lines editor.cm in
  match editor.next with
  | None -> ()
  | Some editor ->
      Editor.set_previous_lines editor.cm count;
      invalidate_from ~editor

let rec refresh_lines_from ~editor =
  let count = Editor.nb_lines editor.cm in
  match editor.next with
  | None -> ()
  | Some editor ->
      Editor.set_previous_lines editor.cm count;
      refresh_lines_from ~editor

let rec run editor =
  if editor.status = Running then ()
  else (
    editor.status <- Request_run;
    editor.errored <- false;
    Editor.clear_messages editor.cm;
    match editor.prev with
    | Some e when e.status <> Run_ok -> run e
    | _ ->
        editor.status <- Running;
        let code_txt = Editor.source editor.cm in
        let line_number = 1 + Editor.get_previous_lines editor.cm in
        Client.eval ~id:editor.id ~line_number editor.worker code_txt)

(* Splice [t] into the doubly-linked cell chain between [prev] and
   [next] (either may be [None]). Unlike a tail-only append, this
   supports insertion in *document order* even when custom elements
   connect out of order (e.g. the host page moves sections around
   before the component script registers). The chain order defines
   the cumulative toplevel/merlin context, so it must match what the
   reader sees on the page. *)
let insert ~prev ~next t =
  t.prev <- prev;
  t.next <- next;
  (match prev with Some p -> p.next <- Some t | None -> ());
  (match next with Some n -> n.prev <- Some t | None -> ());
  (match prev with
  | None -> Editor.set_previous_lines t.cm 0
  | Some p -> Editor.set_previous_lines t.cm (Editor.nb_lines p.cm));
  refresh_lines_from ~editor:t;
  (match next with Some n -> invalidate_from ~editor:n | None -> ())

let set_source_from_html editor this =
  let doc = Webcomponent.text_content this in
  let doc = String.trim doc in
  Editor.set_source editor.cm doc;
  invalidate_from ~editor;
  Client.fmt ~id:editor.id editor.worker doc

let init_css shadow ~extra_style ~inline_style =
  El.append_children shadow
    [
      El.style
        (El.txt (Jstr.of_string [%blob "style.css"])
        ::
        (match inline_style with
        | None -> []
        | Some inline_style ->
            [
              El.txt
              @@ Jstr.of_string (":host{" ^ Jstr.to_string inline_style ^ "}");
            ]));
    ];
  match extra_style with
  | None -> ()
  | Some src_style ->
      El.append_children shadow
        [
          El.link
            ~at:
              [
                At.href src_style;
                At.rel (Jstr.of_string "stylesheet");
                At.type' (Jstr.of_string "text/css");
              ]
            ();
        ]

let init ~id ~run_on ?extra_style ?inline_style worker this =
  let shadow = Webcomponent.attach_shadow this in
  init_css shadow ~extra_style ~inline_style;

  let run_btn = El.button [ El.txt (Jstr.of_string "Run") ] in
  El.append_children shadow
    [ El.div ~at:[ At.class' (Jstr.of_string "run_btn") ] [ run_btn ] ];

  let cm = Editor.make shadow in

  let merlin = Merlin_ext.make ~id worker in
  let merlin_worker = Merlin_ext.Client.make_worker merlin in
  let editor =
    {
      id;
      status = Not_run;
      errored = false;
      cm;
      prev = None;
      next = None;
      worker;
      merlin_worker;
      run_on;
    }
  in
  Editor.on_change cm (fun () -> invalidate_after ~editor);
  set_source_from_html editor this;

  Merlin_ext.set_context merlin (fun () -> pre_source editor);
  Editor.configure_merlin cm (fun () -> Merlin_ext.extensions merlin_worker);

  let () =
    Mutation_observer.observe ~target:(Webcomponent.as_target this)
    @@ Mutation_observer.create (fun _ _ -> set_source_from_html editor this)
  in

  let _ : Ev.listener =
    Ev.listen Ev.click (fun _ev -> run editor) (El.as_target run_btn)
  in

  editor

let set_source editor doc =
  Editor.set_source editor.cm doc;
  refresh_lines_from ~editor

(* Toplevel output is a stream of UTF-8 bytes (an OCaml string). Brr's
   [Jstr.of_string] does not reliably turn those bytes into a JS string
   under this build, so non-ASCII output (e.g. printing "தமிழ்") is
   dropped. Decode the raw bytes through the browser's TextDecoder
   instead; reading with [String.get] is byte-accurate regardless of the
   js_of_ocaml string representation. *)
let jstr_of_utf8 (s : string) : Jstr.t =
  let bytes =
    Array.init (String.length s) (fun i -> Char.code (String.unsafe_get s i))
  in
  let arr = Tarray.of_int_array Tarray.Uint8 bytes in
  let decoder = Jv.new' (Jv.get Jv.global "TextDecoder") [| Jv.of_string "utf-8" |] in
  Jv.to_jstr (Jv.call decoder "decode" [| Tarray.to_jv arr |])

let render_message msg =
  let raw_html s =
    let el = El.div [] in
    let el_t = El.to_jv el in
    Jv.set el_t "innerHTML" (Jv.of_jstr @@ jstr_of_utf8 s);
    el
  in
  let kind, text =
    match msg with
    | X_protocol.Stdout str -> ("stdout", El.txt (jstr_of_utf8 str))
    | Stderr str -> ("stderr", El.txt (jstr_of_utf8 str))
    | Meta str -> ("meta", El.txt (jstr_of_utf8 str))
    | Html str -> ("html", raw_html str)
  in
  El.pre ~at:[ At.class' (Jstr.of_string ("caml_" ^ kind)) ] [ text ]

(* The toplevel reports the source location to anchor output at as a UTF-8
   byte offset; CodeMirror positions are UTF-16 code units. Convert, or a
   non-ASCII cell anchors output past the end of the document and throws. *)
let byte_to_utf16 s byte_off =
  let n = String.length s in
  let rec go i u =
    if i >= byte_off || i >= n then u
    else
      let b = Char.code (String.unsafe_get s i) in
      let len =
        if b < 0x80 then 1 else if b < 0xe0 then 2 else if b < 0xf0 then 3 else 4
      in
      let units = if len = 4 then 2 else 1 in
      go (i + len) (u + units)
  in
  go 0 0

let add_message t loc msg =
  if output_has_error msg then t.errored <- true;
  (* [loc] is a UTF-8 byte offset from the toplevel; CodeMirror positions
     are UTF-16 code units. Convert, or a non-ASCII cell anchors output
     past the end of the document and throws. *)
  let loc = byte_to_utf16 (Editor.source t.cm) loc in
  Editor.add_message t.cm loc (List.map render_message msg)

let completed_run ed msg =
  (if msg <> [] then (
     if output_has_error msg then ed.errored <- true;
     (* byte length of the source; [add_message] maps it to a UTF-16
        offset (the end of the cell) for CodeMirror *)
     let loc = String.length (Editor.source ed.cm) in
     add_message ed loc msg));
  ed.status <- Run_ok;
  match ed.next with Some e when e.status = Request_run -> run e | _ -> ()

let receive_merlin t msg =
  Merlin_ext.Client.on_message t.merlin_worker
    (Merlin_ext.fix_answer ~pre:(pre_source t) ~doc:(Editor.source t.cm) msg)

let loadable t = t.run_on = `Load
