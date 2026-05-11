module Merlin_worker = Worker

let respond m = Js_of_ocaml.Worker.post_message (X_protocol.resp_to_bytes m)

let reformat ~id code =
  let code' =
    try Ocamlfmt.fmt code
    with _err ->
      (* Brr.Console.log [ "ocamlformat error"; Printexc.to_string _err ]; *)
      code
  in
  if code <> code' then respond (Formatted_source (id, code'));
  code'

let run () =
  Js_of_ocaml.Worker.set_onmessage @@ fun marshaled_message ->
  match X_protocol.req_of_bytes marshaled_message with
  | Merlin (id, action) ->
      respond (Merlin_response (id, Merlin_worker.on_message action))
  | Format (id, code) -> ignore (reformat ~id code : string)
  | Eval (id, code) ->
      let code = reformat ~id code in
      let output ~loc out = respond (Top_response_at (id, loc, out)) in
      let result = Eval.execute ~output ~id code in
      respond (Top_response (id, result))
  | Setup ->
      Eval.setup_toplevel ();
      (* Refresh merlin's [Load_path] cache so any cmi files an
         extension bundle wrote into [/static/cmis/] at importScripts
         time become visible to Type_enclosing queries. Run after
         [setup_toplevel] (which calls [Topdirs.dir_directory] for
         the toplevel side); guard with [try] because [Load_path] may
         not yet be initialised on a fresh worker, in which case
         there's nothing to invalidate. *)
      (try Merlin_worker.reset_dirs () with _ -> ())
