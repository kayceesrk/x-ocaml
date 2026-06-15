module Worker = Brr_webworkers.Worker

type t = { id : int; mutable context : unit -> string; client : Client.t }

let set_context t fn = t.context <- fn

let make ~id client =
  { id; context = (fun () -> failwith "Merlin_ext.context"); client }

(* merlin speaks UTF-8 byte offsets (pos_cnum); CodeMirror speaks UTF-16
   code-unit offsets. For non-ASCII source the two diverge, which made
   merlin's lint place diagnostics out of range and throw. Convert at this
   boundary so the rest of the editor can stay in CodeMirror units. *)
let utf8_seq_len b =
  if b < 0x80 then 1 else if b < 0xe0 then 2 else if b < 0xf0 then 3 else 4

let utf16_units cp = if cp >= 0x10000 then 2 else 1

let decode_cp s i =
  let n = String.length s in
  let byte k = if k < n then Char.code (String.unsafe_get s k) else 0 in
  let b0 = byte i in
  let len = utf8_seq_len b0 in
  let cp =
    match len with
    | 1 -> b0
    | 2 -> ((b0 land 0x1f) lsl 6) lor (byte (i + 1) land 0x3f)
    | 3 ->
        ((b0 land 0x0f) lsl 12)
        lor ((byte (i + 1) land 0x3f) lsl 6)
        lor (byte (i + 2) land 0x3f)
    | _ ->
        ((b0 land 0x07) lsl 18)
        lor ((byte (i + 1) land 0x3f) lsl 12)
        lor ((byte (i + 2) land 0x3f) lsl 6)
        lor (byte (i + 3) land 0x3f)
  in
  (cp, len)

(* byte offset -> UTF-16 code-unit offset within [s] *)
let byte_to_utf16 s byte_off =
  let n = String.length s in
  let rec go i u =
    if i >= byte_off || i >= n then u
    else
      let cp, len = decode_cp s i in
      go (i + len) (u + utf16_units cp)
  in
  go 0 0

(* UTF-16 code-unit offset -> byte offset within [s] *)
let utf16_to_byte s u_off =
  let n = String.length s in
  let rec go i u =
    if u >= u_off || i >= n then i
    else
      let cp, len = decode_cp s i in
      go (i + len) (u + utf16_units cp)
  in
  go 0 0

(* request positions come from CodeMirror (UTF-16, into [src]); send a byte
   offset into the merlin buffer [pre ^ src]. *)
let fix_position ~src ~pre_len = function
  | `Offset at -> `Offset (utf16_to_byte src at + pre_len)
  | other -> other

(* answer locations come from merlin (byte offsets into [pre ^ src]); hand
   CodeMirror UTF-16 offsets into [src]. *)
let fix_loc ~src ~pre_len ({ loc_start; loc_end; _ } as loc : Protocol.Location.t)
    =
  let to_cm c = byte_to_utf16 src (c - pre_len) in
  {
    loc with
    loc_start = { loc_start with pos_cnum = to_cm loc_start.pos_cnum };
    loc_end = { loc_end with pos_cnum = to_cm loc_end.pos_cnum };
  }

let fix_request t msg =
  let pre = t.context () in
  let pre_len = String.length pre in
  match msg with
  | Protocol.Complete_prefix (src, position) ->
      let position = fix_position ~src ~pre_len position in
      Protocol.Complete_prefix (pre ^ src, position)
  | Protocol.Type_enclosing (src, position) ->
      let position = fix_position ~src ~pre_len position in
      Protocol.Type_enclosing (pre ^ src, position)
  | Protocol.All_errors src -> Protocol.All_errors (pre ^ src)
  | Protocol.Add_cmis _ as other -> other

let fix_answer ~pre ~doc msg =
  let src = doc in
  let pre_len = String.length pre in
  match (msg : Protocol.answer) with
  | Protocol.Errors errors ->
      Protocol.Errors
        (List.filter_map
           (fun (e : Protocol.error) ->
             (* filter on the byte offset before converting, so positions
                inside the prepended context (negative in [src]) drop out *)
             let bstart = e.loc.loc_start.pos_cnum - pre_len in
             let bend = e.loc.loc_end.pos_cnum - pre_len in
             if bstart < 0 || bend < 0 then None
             else Some { e with loc = fix_loc ~src ~pre_len e.loc })
           errors)
  | Protocol.Completions completions ->
      Completions
        {
          completions with
          from = byte_to_utf16 src (completions.from - pre_len);
          to_ = byte_to_utf16 src (completions.to_ - pre_len);
        }
  | Protocol.Typed_enclosings typed_enclosings ->
      Typed_enclosings
        (List.map
           (fun (loc, a, b) -> (fix_loc ~src ~pre_len loc, a, b))
           typed_enclosings)
  | Protocol.Added_cmis -> msg

module Merlin_send = struct
  type nonrec t = t

  let post t msg =
    let msg = fix_request t msg in
    Client.post t.client (Merlin (t.id, msg))
end

module Client = Merlin_client.Make (Merlin_send)
module Ed = Merlin_codemirror.Extensions (Merlin_send)

let extensions t =
  Merlin_codemirror.ocaml :: Array.to_list (Ed.all_extensions t)
