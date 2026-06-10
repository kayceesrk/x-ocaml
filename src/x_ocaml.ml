let all : Cell.t list ref = ref []
let find_by_id id = List.find (fun t -> Cell.id t = id) !all

let current_script =
  Brr.El.of_jv (Jv.get (Brr.Document.to_jv Brr.G.document) "currentScript")

let current_attribute attr = Brr.El.at (Jstr.of_string attr) current_script

let extra_load =
  match current_attribute "src-load" with
  | None -> None
  | Some url -> Some (Jstr.to_string url)

let worker_url =
  match current_attribute "src-worker" with
  | None -> failwith "x-ocaml script missing src-worker attribute"
  | Some url -> Jstr.to_string url

let worker = Client.make ?extra_load worker_url

let () =
  Client.on_message worker @@ function
  | Formatted_source (id, code_fmt) -> Cell.set_source (find_by_id id) code_fmt
  | Top_response_at (id, loc, msg) -> Cell.add_message (find_by_id id) loc msg
  | Top_response (id, msg) -> Cell.completed_run (find_by_id id) msg
  | Merlin_response (id, msg) -> Cell.receive_merlin (find_by_id id) msg

let () = Client.post worker Setup

let elt_name =
  match current_attribute "elt-name" with
  | None -> Jstr.of_string "x-ocaml"
  | Some name -> name

(* Cells in ascending document order. connectedCallback firing order
   is NOT document order when the host page reparents sections (the
   NPTEL build moves slide sections into a reveal.js deck), so each
   new cell is inserted at its document position via
   compareDocumentPosition. The chain order defines the cumulative
   toplevel/merlin context. *)
let chain : (Cell.t * Jv.t) list ref = ref []

let _ =
  Webcomponent.define elt_name @@ fun this ->
  let id = List.length !all in
  let editor = Cell.init ~id worker this in
  all := editor :: !all;
  let this_jv = Brr.El.to_jv (Webcomponent.as_target this) in
  let precedes el =
    (* DOCUMENT_POSITION_FOLLOWING (4): [this] follows [el]. *)
    let mask = Jv.to_int (Jv.call el "compareDocumentPosition" [| this_jv |]) in
    mask land 4 <> 0
  in
  let rec split before rest =
    match rest with
    | (c, el) :: tl when precedes el -> split ((c, el) :: before) tl
    | _ -> (before, rest)
  in
  let before_rev, after = split [] !chain in
  let prev = match before_rev with [] -> None | (c, _) :: _ -> Some c in
  let next = match after with [] -> None | (c, _) :: _ -> Some c in
  chain := List.rev_append before_rev ((editor, this_jv) :: after);
  Cell.insert ~prev ~next editor;
  ()
