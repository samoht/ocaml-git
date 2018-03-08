module type S = sig

  include Git.S
  val create: Fpath.t -> (t, error) result Lwt.t
end

module Make0 (Source: Test_data.SOURCE) (Store: S) = struct

  open Lwt.Infix

  let pwd = Unix.getcwd ()
  let root = Fpath.(v pwd / "test-data" / Source.name)

  module Sync = Git.Sync.Common(Store)

  type delta =
    [ `Diff of Store.Hash.t * Store.Hash.t
    | `New of Store.Hash.t ]

  type difference =
    { reference              : Store.Reference.t
    ; delta                  : delta
    ; fake_remote_references : (Store.Hash.t * string * bool) list
    ; fake_commands          : Sync.command list }

  let diff ~reference from_ to_ =
    { reference
    ; delta = `Diff (from_, to_)
    ; fake_remote_references = [ from_, Store.Reference.to_string reference, false ]
    ; fake_commands          = [ `Update (from_, to_, reference) ] }

  let make ~reference hash =
    { reference
    ; delta = `New hash
    ; fake_remote_references = []
    ; fake_commands = [ `Create (hash, reference) ] }

  let ( >>?= ) = Lwt_result.bind

  let consume stream =
    let rec go () =
      stream () >>= function
      | Some _ -> go ()
      | None -> Lwt.return () in
    go ()

  let rev_list t fake_remote_references fake_commands : (Store.Hash.t list, Store.error) result Lwt.t =
    Sync.packer t ~ofs_delta:true fake_remote_references fake_commands
    >>?= (fun (stream, idx) ->
      consume stream
      >>= fun () -> Lwt_mvar.take idx
      >|= fun graph -> Store.Pack.Graph.fold (fun hash _ acc -> hash :: acc) graph []
        |> fun v -> Ok v)

  let rev_list t cs =
    let fake_remote_references =
      List.fold_left
        (fun acc -> function
          | { fake_remote_references
            ; _ } -> List.fold_left (fun acc (hash, reference, peeled) -> Store.Reference.Map.add (Store.Reference.of_string reference) (hash, peeled) acc) acc fake_remote_references)
        Store.Reference.Map.empty cs
      |> Store.Reference.Map.bindings
      |> List.map (fun (reference, (hash, peeled)) -> (hash, Store.Reference.to_string reference, peeled)) in
    let module OrderedCommand = struct type t = Sync.command let compare a b = match a, b with
                                         | `Create (a, _), `Create (b, _) -> Store.Hash.compare a b
                                         | `Delete (a, _), `Delete (b, _) -> Store.Hash.compare a b
                                         | `Update (a, b, _), `Update (c, d, _) ->
                                            let ret = Store.Hash.compare a c in
                                            if ret = 0 then Store.Hash.compare b d else ret
                                         | `Create _, _ -> 1
                                         | `Delete _, `Create _ -> (-1)
                                         | `Delete _, _ -> 1
                                         | `Update _, `Create _ -> (-1)
                                         | `Update _, `Delete _ -> (-1) end in
    let module Set = Set.Make(OrderedCommand) in
    let fake_commands =
      List.fold_left (fun acc { fake_commands; _ } -> List.fold_left (fun acc x -> Set.add x acc) acc fake_commands)
        Set.empty cs
      |> Set.elements in
    rev_list t fake_remote_references fake_commands

  let input_rev_list = function
    | { delta = `Diff (from_, to_); _ } ->
       [ `Negative from_; `Object to_ ]
    | { delta = `New hash; _ } ->
       [ `Object hash ]

  let git_rev_list cs =
    let command = Fmt.strf "git rev-list --objects --stdin" in
    let input = fun oc ->
      let ppf = Format.formatter_of_out_channel oc in
      let pp_elt ppf = function
        | `Negative hash -> Fmt.pf ppf "^%a" Store.Hash.pp hash
        | `Object hash -> Store.Hash.pp ppf hash in
      Fmt.(pf ppf) "%a\n%!" Fmt.(list ~sep:(const string "\n") pp_elt) (List.concat (List.map input_rev_list cs)) in
    let git_dir = Fpath.(root / ".git") in
    let env =
      [| Fmt.strf "GIT_DIR=%a" Fpath.pp git_dir |] in

    let output = Test_data.output_of_command ~env ~input command in
    let lines = Astring.String.cuts ~sep:"\n" output in

    List.fold_left
      (fun acc line ->
        try let hex = String.sub line 0 (Store.Hash.Digest.length * 2) in Store.Hash.of_hex hex :: acc
        with _ -> acc)
      [] lines

  module C = Test_common.Make(Store)
  open C

  let rev_list_test name cs () =
    let expect = git_rev_list cs in

    match Lwt_main.run (Store.create root >>?= fun t -> rev_list t cs) with
    | Ok have -> assert_keys_equal name expect have
    | Error err -> Alcotest.failf "Retrieve an error: %a." Store.pp_error err
end

module type R = sig

  type hash
  type t = [ `Diff of hash * hash
           | `New of hash ]

  val lst : (string * t) list
end

let suite _name (module F: Test_data.SOURCE) (module S: S) (module R: R with type hash = S.Hash.t) =
  let module T = Make0(F)(S) in
  (Fmt.strf "%s - rev-list" F.name),
  List.map (function
      | (name, `Diff (from_, to_)) ->
         let c = T.diff ~reference:S.Reference.master from_ to_ in
         name, `Quick, T.rev_list_test name [ c ]
      | (name, `New hash) ->
         let c = T.make ~reference:S.Reference.master hash in
         name, `Quick, T.rev_list_test name [ c ])
    R.lst
