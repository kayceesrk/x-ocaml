type t = {
  view : Code_mirror.Editor.View.t;
  messages_comp : Code_mirror.Compartment.t;
  lines_comp : Code_mirror.Compartment.t;
  merlin_comp : Code_mirror.Compartment.t;
  mutable merlin_extension : unit -> Code_mirror.Extension.t list;
  changes : Code_mirror.Compartment.t;
  mutable previous_lines : int;
  mutable current_doc : string;
  mutable messages : (int * Brr.El.t list) list;
}

let find_line_ends at doc =
  let rec go i =
    if i >= String.length doc || doc.[i] = '\n' then i else go (i + 1)
  in
  go at

(* [current_doc] is UTF-8 bytes; CodeMirror positions are UTF-16 code
   units. Convert between the two so byte-based line scanning produces
   in-range CodeMirror offsets for non-ASCII source. *)
let utf8_seq_len b =
  if b < 0x80 then 1 else if b < 0xe0 then 2 else if b < 0xf0 then 3 else 4

let cp_utf16_units lead = if lead >= 0xf0 then 2 else 1

let byte_to_utf16 s byte_off =
  let n = String.length s in
  let rec go i u =
    if i >= byte_off || i >= n then u
    else
      let b = Char.code (String.unsafe_get s i) in
      go (i + utf8_seq_len b) (u + cp_utf16_units b)
  in
  go 0 0

let utf16_to_byte s u_off =
  let n = String.length s in
  let rec go i u =
    if u >= u_off || i >= n then i
    else
      let b = Char.code (String.unsafe_get s i) in
      go (i + utf8_seq_len b) (u + cp_utf16_units b)
  in
  go 0 0

let render_messages cm =
  let open Code_mirror.Editor in
  let open Code_mirror.Decoration in
  let (State.Facet ((module F), it)) = View.decorations () in
  let doc = cm.current_doc in
  let ranges =
    Array.of_list
    @@ List.map (fun (at, msg) ->
           (* [at] is a CodeMirror (UTF-16) offset; scan for the line end in
              byte space, then map back to UTF-16 *)
           let at = byte_to_utf16 doc (find_line_ends (utf16_to_byte doc at) doc) in
           range ~from:at ~to_:at
           @@ widget ~block:true ~side:99
           @@ Widget.make (fun () -> msg))
    @@ List.concat
    @@ List.map (fun (loc, lst) -> List.map (fun m -> (loc, m)) lst)
    @@ List.sort (fun (a, _) (b, _) -> Int.compare a b) cm.messages
  in
  F.of_ it (Range_set.of' ranges)

let refresh_messages ed =
  Code_mirror.Editor.View.dispatch ed.view
    (Code_mirror.Compartment.reconfigure ed.messages_comp
       [ render_messages ed ])

let custom_ln editor =
  Code_mirror.Editor.View.line_numbers (fun x ->
      string_of_int (editor.previous_lines + x))

let refresh_lines ed =
  Code_mirror.Editor.View.dispatch ed.view
  @@ Code_mirror.Compartment.reconfigure ed.lines_comp [ custom_ln ed ]

let refresh_merlin ed =
  Code_mirror.Editor.View.dispatch ed.view
  @@ Code_mirror.Compartment.reconfigure ed.merlin_comp (ed.merlin_extension ())

let configure_merlin ed extension =
  ed.merlin_extension <- extension;
  refresh_merlin ed

let clear x =
  x.messages <- [];
  refresh_lines x;
  refresh_messages x;
  refresh_merlin x

let source_of_state s =
  String.concat "\n" @@ Array.to_list @@ Array.map Jstr.to_string
  @@ Code_mirror.Text.to_jstr_array
  @@ Code_mirror.Editor.State.doc s

let source t = source_of_state @@ Code_mirror.Editor.View.state t.view

(* CodeMirror document length, in UTF-16 code units. This is the unit
   CodeMirror positions use; [String.length (source t)] is the UTF-8
   byte length, which overshoots for non-ASCII source and makes
   message placement throw "Position N out of range". *)
let doc_length t =
  Code_mirror.Text.length
  @@ Code_mirror.Editor.State.doc
  @@ Code_mirror.Editor.View.state t.view

let prefix_length a b =
  let rec go i =
    if i >= String.length a || i >= String.length b || a.[i] <> b.[i] then i
    else go (i + 1)
  in
  go 0

let basic_setup =
  Jv.get Jv.global "__CM__basic_setup" |> Code_mirror.Extension.of_jv

let make parent =
  let open Code_mirror.Editor in
  let changes = Code_mirror.Compartment.make () in
  let messages = Code_mirror.Compartment.make () in
  let lines = Code_mirror.Compartment.make () in
  let merlin = Code_mirror.Compartment.make () in
  let extensions =
    [|
      basic_setup;
      Code_mirror.Editor.View.line_wrapping ();
      Code_mirror.Compartment.of' lines [];
      Code_mirror.Compartment.of' messages [];
      Code_mirror.Compartment.of' changes [];
      Code_mirror.Compartment.of' merlin [];
    |]
  in
  let config = State.Config.create ~doc:Jstr.empty ~extensions () in
  let state = State.create ~config () in
  let opts = View.opts ~state ~parent () in
  let view = View.create ~opts () in
  {
    previous_lines = 0;
    current_doc = "";
    messages = [];
    view;
    messages_comp = messages;
    lines_comp = lines;
    merlin_comp = merlin;
    merlin_extension = (fun () -> []);
    changes;
  }

let set_current_doc t new_doc =
  let at = prefix_length t.current_doc new_doc in
  t.current_doc <- new_doc;
  t.messages <- List.filter (fun (loc, _) -> loc < at) t.messages;
  refresh_messages t

let on_change cm fn =
  let has_changed =
    let open Code_mirror.Editor in
    let (State.Facet ((module F), it)) = View.update_listener () in
    F.of_ it (fun ev ->
        if View.Update.doc_changed ev then
          let new_doc = source_of_state (View.Update.state ev) in
          if not (String.equal cm.current_doc new_doc) then (
            set_current_doc cm new_doc;
            fn ()))
  in
  Code_mirror.Editor.View.dispatch cm.view
  @@ Code_mirror.Compartment.reconfigure cm.changes [ has_changed ]

let count_lines str =
  if str = "" then 0
  else
    let nb = ref 1 in
    for i = 0 to String.length str - 1 do
      if str.[i] = '\n' then incr nb
    done;
    !nb

let nb_lines t = t.previous_lines + count_lines t.current_doc
let get_previous_lines t = t.previous_lines

let set_previous_lines t nb =
  t.previous_lines <- nb;
  refresh_lines t

let set_messages t msg =
  t.messages <- msg;
  refresh_messages t

let clear_messages t = set_messages t []
let add_message t loc msg = set_messages t ((loc, msg) :: t.messages)

(* [doc] is UTF-8 bytes; decode to a JS string so CodeMirror's document
   length is in UTF-16 units (matching its positions). Jstr.of_string does
   not reliably decode here, leaving the doc at its byte length, which makes
   decoration mapping throw for non-ASCII source. *)
let jstr_of_utf8 (s : string) : Jstr.t =
  let bytes =
    Array.init (String.length s) (fun i -> Char.code (String.unsafe_get s i))
  in
  let arr = Brr.Tarray.of_int_array Brr.Tarray.Uint8 bytes in
  let decoder =
    Jv.new' (Jv.get Jv.global "TextDecoder") [| Jv.of_string "utf-8" |]
  in
  Jv.to_jstr (Jv.call decoder "decode" [| Brr.Tarray.to_jv arr |])

let set_source t doc =
  set_current_doc t doc;
  Code_mirror.Editor.View.set_doc t.view (jstr_of_utf8 doc)
