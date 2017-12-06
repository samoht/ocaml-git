(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 * and Romain Calascibetta <romain.calascibetta@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix
let ( >!= ) = Lwt_result.bind_lwt_err
let ( >?= ) = Lwt_result.bind

module Default = struct
  let capabilites =
    [ `Multi_ack_detailed
    ; `Thin_pack
    ; `Side_band_64k
    ; `Ofs_delta
    ; `Agent "git/2.0.0"
    ; `Report_status
    ; `No_done ]
end

module Option =
struct
  let mem v x ~equal = match v with Some x' -> equal x x' | None -> false
  let value_exn v ~error =
    match v with Some v -> v | None -> raise (Invalid_argument error)
end

module type CLIENT = sig
  type headers
  type body
  type resp
  type meth
  type uri

  type +'a io

  val call : ?headers:headers -> ?body:body -> meth -> uri -> resp io
end

module type FLOW = sig
  type raw

  type +'a io

  type i = (raw * int * int) option -> unit io
  type o = unit -> (raw * int * int) option io
end

module Lwt_cstruct_flow = struct
  type raw = Cstruct.t

  type +'a io = 'a Lwt.t

  type i = (raw * int * int) option -> unit io
  type o = unit -> (raw * int * int) option io
end

module type S_EXT = sig
  module Web: Web.S
  module Client: CLIENT
    with type headers = Web.HTTP.headers
     and type meth = Web.HTTP.meth
     and type uri = Web.uri
     and type resp = Web.resp
  module Store: Git.S

  module Decoder: Git.Smart.DECODER
    with module Hash = Store.Hash
  module Encoder: Git.Smart.ENCODER
    with module Hash = Store.Hash

  module PACKDecoder: Git.Unpack.P
    with module Hash = Store.Hash
     and module Inflate = Store.Inflate

  type error =
    [ `SmartDecoder of Decoder.error
    | `StorePack of Store.Pack.error
    | `Clone of string
    | `ReportStatus of string
    | `Ref of Store.Ref.error ]

  val pp_error: error Fmt.t

  val ls:
       Store.t
    -> ?headers:Web.HTTP.headers
    -> ?https:bool
    -> ?port:int
    -> ?capabilities:Git.Capability.t list
    -> string -> string -> (Decoder.advertised_refs, error) result Lwt.t

  type command =
    [ `Create of (Store.Hash.t * Store.Reference.t)
    | `Delete of (Store.Hash.t * Store.Reference.t)
    | `Update of (Store.Hash.t * Store.Hash.t * Store.Reference.t) ]

  val push:
       Store.t
    -> push:(Store.t -> (Store.Hash.t * Store.Reference.t * bool) list -> (Store.Hash.t list * command list) Lwt.t)
    -> ?headers:Web.HTTP.headers
    -> ?https:bool
    -> ?port:int
    -> ?capabilities:Git.Capability.t list
    -> string -> string -> ((string, string * string) result list, error) result Lwt.t

  val fetch:
       Store.t
    -> ?shallow:Store.Hash.t list
    -> ?stdout:(Cstruct.t -> unit Lwt.t)
    -> ?stderr:(Cstruct.t -> unit Lwt.t)
    -> ?headers:Web.HTTP.headers
    -> ?https:bool
    -> ?capabilities:Git.Capability.t list
    -> negociate:((Decoder.acks -> 'state -> ([ `Ready | `Done | `Again of Store.Hash.t list ] * 'state) Lwt.t) * 'state)
    -> has:Store.Hash.t list
    -> want:((Store.Hash.t * Store.Reference.t * bool) list -> (Store.Reference.t * Store.Hash.t) list Lwt.t)
    -> ?deepen:[ `Depth of int | `Timestamp of int64 | `Ref of string ]
    -> ?port:int
    -> string -> string -> ((Store.Reference.t * Store.Hash.t) list * int, error) result Lwt.t

  val clone_ext:
       Store.t
    -> ?stdout:(Cstruct.t -> unit Lwt.t)
    -> ?stderr:(Cstruct.t -> unit Lwt.t)
    -> ?headers:Web.HTTP.headers
    -> ?https:bool
    -> ?port:int
    -> ?reference:Store.Reference.t
    -> ?capabilities:Git.Capability.t list
    -> string -> string -> (Store.Hash.t, error) result Lwt.t

  val fetch_some:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Git.Capability.t list ->
    references:(Store.Reference.t * Store.Reference.t) list ->
    Uri.t -> (unit, error) result Lwt.t

  val fetch_all:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Git.Capability.t list ->
    references:(Store.Reference.t * Store.Reference.t) list ->
    Uri.t -> ((Store.Reference.t * Store.Hash.t) list, error) result Lwt.t

  val fetch_one:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Git.Capability.t list ->
    reference:(Store.Reference.t * Store.Reference.t) ->
    Uri.t -> (unit, error) result Lwt.t

  val clone:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Git.Capability.t list ->
    reference:(Store.Reference.t * Store.Reference.t) ->
    Uri.t -> (unit, error) result Lwt.t

  val update: Store.t ->
    ?capabilities:Git.Capability.t list ->
    reference:Store.Reference.t -> Uri.t ->
    ((Store.Reference.t, Store.Reference.t * string) result list, error) result Lwt.t

end

module type S = S_EXT
  with type Web.req = Web_cohttp_lwt.req
   and type Web.resp = Web_cohttp_lwt.resp
   and type 'a Web.io = 'a Web_cohttp_lwt.io
   and type Web.raw = Web_cohttp_lwt.raw
   and type Web.uri = Web_cohttp_lwt.uri
   and type Web.Request.body = Web_cohttp_lwt.Request.body
   and type Web.Response.body = Web_cohttp_lwt.Response.body
   and type Web.HTTP.headers = Web_cohttp_lwt.HTTP.headers

module Make_ext
    (W: Web.S
     with type +'a io = 'a Lwt.t
      and type raw = Cstruct.t
      and type uri = Uri.t
      and type Request.body = Lwt_cstruct_flow.i
      and type Response.body = Lwt_cstruct_flow.o)
    (C: CLIENT
     with type +'a io = 'a W.io
      and type headers = W.HTTP.headers
      and type body = Lwt_cstruct_flow.o
      and type meth = W.HTTP.meth
      and type uri = W.uri
      and type resp = W.resp)
    (G: Git.S)
= struct
  module Web = W
  module Client = C
  module Store = G

  module Decoder = Git.Smart.Decoder(Store.Hash)
  module Encoder = Git.Smart.Encoder(Store.Hash)

  module PACKDecoder
    = Git.Unpack.MakePACKDecoder(Store.Hash)(Store.Inflate)

  type error =
    [ `SmartDecoder of Decoder.error
    | `StorePack of Store.Pack.error
    | `Clone of string
    | `ReportStatus of string
    | `Ref of Store.Ref.error ]

  let pp_error ppf = function
    | `SmartDecoder err  -> Fmt.pf ppf "(`SmartDecoder %a)" Decoder.pp_error err
    | `StorePack err     -> Fmt.pf ppf "(`StorePack %a)" Store.Pack.pp_error err
    | `Clone err         -> Fmt.pf ppf "(`Clone %s)" err
    | `ReportStatus err  -> Fmt.pf ppf "(`ReportStatus %s)" err
    | `Ref err           -> Fmt.pf ppf "(`Ref %a)" Store.Ref.pp_error err

  module Log =
  struct
    let src = Logs.Src.create "git.sync.http" ~doc:"logs git's sync http event"
    include (val Logs.src_log src : Logs.LOG)
  end

  let option_map_default f v = function
    | Some v -> f v
    | None -> v

  let default_stdout raw =
    Log.info (fun l -> l ~header:"populate:stdout" "%S" (Cstruct.to_string raw));
    Lwt.return ()

  let default_stderr raw =
    Log.err (fun l -> l ~header:"populate:stderr" "%S" (Cstruct.to_string raw));
    Lwt.return ()

  let populate git ?(stdout = default_stdout) ?(stderr = default_stderr) stream =
    let cstruct_copy cs =
      let ln = Cstruct.len cs in
      let rt = Cstruct.create ln in
      Cstruct.blit cs 0 rt 0 ln;
      rt
    in
    let stream', push = Lwt_stream.create () in
    let rec dispatch () =
      stream () >>= function
      | Ok (`Out raw) ->
        stdout raw >>= dispatch
      | Ok (`Raw raw) ->
        Log.debug (fun l -> l ~header:"dispatch" "Retrieve a chunk of the PACK stream (length: %d)."
                      (Cstruct.len raw));
        push (Some (cstruct_copy raw));
        dispatch ()
      | Ok (`Err raw) ->
        stderr raw >>= dispatch
      | Ok `End ->
        Log.debug (fun l -> l ~header:"dispatch" "Retrieve end of the PACK stream.");
        push None;
        Lwt.return (Ok ())
      | Error err -> Lwt.return (Error (`SmartDecoder err))
    in
    dispatch () >?= fun () ->
      (Store.Pack.from git (fun () -> Lwt_stream.get stream')
       >!= fun err -> Lwt.return (`StorePack err))

  let producer ?(final = (fun () -> Lwt.return None)) state =
    let state' = ref (fun () -> state) in

    let go () = match !state' () with
      | Encoder.Write { buffer; off; len; continue; } ->
        state' := (fun () -> continue len);
        Lwt.return (Some (buffer, off, len))
      | Encoder.Ok () ->
        (* ensure to jump only in this case (it's a concat stream). *)
        state' := (fun () -> Encoder.Ok ());
        final ()
    in go

  let rec consume stream ?keep state =
    match state with
    | Decoder.Ok v -> Lwt.return (Ok v)
    | Decoder.Error { err; _ } -> Lwt.return (Error err)
    | Decoder.Read { buffer; off; len; continue; } ->
      (match keep with
       | Some (raw, off', len') ->
         Lwt.return (Some (raw, off', len'))
       | None ->
         stream ()) >>= function
      | Some (raw, off', len') ->
        let len'' = min len len' in
        Cstruct.blit raw off' buffer off len'';

        Log.debug (fun l -> l ~header:"consume" "%a"
                      (Fmt.hvbox (Git.Minienc.pp_scalar ~get:Cstruct.get_char ~length:Cstruct.len))
                      (Cstruct.sub raw off' len''));

        if len' - len'' = 0
        then consume stream (continue len'')
        else consume stream ~keep:(raw, off' + len'', len' - len'') (continue len'')
      | None ->
        consume stream (continue 0)

  let ls _ ?headers ?(https = false) ?port ?(capabilities=Default.capabilites)
      host path =
    let scheme = if https then "https" else "http" in
    let uri =
      Uri.empty
      |> (fun uri -> Uri.with_scheme uri (Some scheme))
      |> (fun uri -> Uri.with_host uri (Some host))
      |> (fun uri -> Uri.with_path uri (String.concat "/" [ path; "info"; "refs" ]))
      |> (fun uri -> Uri.with_port uri port)
      |> (fun uri -> Uri.add_query_param uri ("service", [ "git-upload-pack" ]))
    in
    Log.debug (fun l -> l ~header:"ls" "Launch the GET request to %a."
                  Uri.pp_hum uri);
    let git_agent =
      List.fold_left (fun acc -> function `Agent s -> Some s | _ -> acc)
        None capabilities
      |> function
      | Some git_agent -> git_agent
      | None -> raise (Invalid_argument "Expected an user agent in capabilities.")
    in
    let headers =
      option_map_default
        Web.HTTP.Headers.(def user_agent git_agent)
        Web.HTTP.Headers.(def user_agent git_agent empty)
        headers
    in
    Client.call ~headers `GET uri >>= fun resp ->
    let decoder = Decoder.decoder () in
    consume (Web.Response.body resp) (Decoder.decode decoder (Decoder.HttpReferenceDiscovery "git-upload-pack"))
    >!= (fun err -> Lwt.return (`SmartDecoder err))

  type command =
    [ `Create of (Store.Hash.t * Store.Reference.t)
    | `Delete of (Store.Hash.t * Store.Reference.t)
    | `Update of (Store.Hash.t * Store.Hash.t * Store.Reference.t) ]

  module Revision = Git.Revision.Make(Store)

  let packer ~window ~depth git ~ofs_delta:_ remote commands =
    let commands' =
      (List.map (fun (hash, refname, _) -> Encoder.Delete (hash, refname)) remote)
      @ commands
    in

    (* XXX(dinosaure): we don't want to delete remote references but
       we want to exclude any commit already stored remotely. Se, we «
       delete » remote references from the result set. *)

    Lwt_list.fold_left_s
      (fun acc -> function
         | Encoder.Create _ -> Lwt.return acc
         | Encoder.Update (hash, _, _) ->
           Revision.(Range.normalize git (Range.Include (from_hash hash)))
           >|= Store.Hash.Set.union acc
         | Encoder.Delete (hash, _) ->
           Revision.(Range.normalize git (Range.Include (from_hash hash)))
           >|= Store.Hash.Set.union acc)
      Store.Hash.Set.empty commands'
    >>= fun negative ->
    Lwt_list.fold_left_s
      (fun acc -> function
         | Encoder.Create (hash, _) ->
           Revision.(Range.normalize git (Range.Include (from_hash hash)))
           >|= Store.Hash.Set.union acc
         | Encoder.Update (_, hash, _) ->
           Revision.(Range.normalize git (Range.Include (from_hash hash)))
           >|= Store.Hash.Set.union acc
         | Encoder.Delete _ -> Lwt.return acc)
      Store.Hash.Set.empty commands
    >|= (fun positive -> Revision.Range.E.diff positive negative)
    >>= fun elements ->
    Lwt_list.fold_left_s
      (fun acc commit ->
         Store.fold git
           (fun acc ?name:_ ~length:_ _ value -> Lwt.return (value :: acc))
           ~path:(Fpath.v "/") acc commit)
      [] (Store.Hash.Set.elements elements)
    >>= fun entries -> Store.Pack.make git ~window ~depth entries

  let push git ~push
      ?headers ?(https = false) ?port ?(capabilities=Default.capabilites)
      host path =
    let scheme = if https then "https" else "http" in
    let uri =
      Uri.empty
      |> (fun uri -> Uri.with_scheme uri (Some scheme))
      |> (fun uri -> Uri.with_host uri (Some host))
      |> (fun uri -> Uri.with_path uri (String.concat "/" [ path; "info"; "refs" ]))
      |> (fun uri -> Uri.with_port uri port)
      |> (fun uri -> Uri.add_query_param uri ("service", [ "git-receive-pack" ]))
    in

    Log.debug (fun l -> l ~header:"push" "Launch the GET request to %a."
                  Uri.pp_hum uri);

    let git_agent =
      List.fold_left (fun acc -> function `Agent s -> Some s | _ -> acc)
        None capabilities
      |> function
      | Some git_agent -> git_agent
      | None -> raise (Invalid_argument "Expected an user agent in capabilities.")
    in

    let headers =
      option_map_default
        Web.HTTP.Headers.(def user_agent git_agent)
        Web.HTTP.Headers.(def user_agent git_agent empty)
        headers
    in

    Client.call ~headers `GET uri >>= fun resp ->

    let decoder = Decoder.decoder () in
    let encoder = Encoder.encoder () in

    consume (Web.Response.body resp) (Decoder.decode decoder (Decoder.HttpReferenceDiscovery "git-receive-pack")) >>= function
    | Error err ->
      Log.err (fun l -> l ~header:"push" "The HTTP decoder returns an error: %a." Decoder.pp_error err);
      Lwt.return (Error (`SmartDecoder err))
    | Ok refs ->
      let common =
        List.filter (fun x ->
            List.exists ((=) x) capabilities
          ) refs.Decoder.capabilities
      in
      let sideband =
        if List.exists ((=) `Side_band_64k) common
        then `Side_band_64k
        else if List.exists ((=) `Side_band) common
        then `Side_band
        else `No_multiplexe
      in

      Lwt_list.map_p (fun (hash, refname, peeled) -> Lwt.return (hash, Store.Reference.of_string refname, peeled)) refs.Decoder.refs
      >>= push git >>= function
      | (_, []) -> Lwt.return (Ok [])
      | (shallow, commands) ->
        let req =
          Web.Request.v
            `POST
            ~path:[ path; "git-receive-pack" ]
            Web.HTTP.Headers.(def content_type "application/x-git-receive-pack-request" headers)
            (fun _ -> Lwt.return ())
        in

        let x, r =
          List.map (function
              | `Create (hash, reference) -> Encoder.Create (hash, Store.Reference.to_string reference)
              | `Delete (hash, reference) -> Encoder.Delete (hash, Store.Reference.to_string reference)
              | `Update (_of, _to, reference) -> Encoder.Update (_of, _to, Store.Reference.to_string reference))
            commands
          |> fun commands -> List.hd commands, List.tl commands
        in

        packer ~window:(`Object 10) ~depth:50 ~ofs_delta:true git refs.Decoder.refs (x :: r) >>= function
        | Error _ -> assert false
        | Ok (stream, _) ->
          let stream () = stream () >>= function
            | Some buf -> Lwt.return (Some (buf, 0, Cstruct.len buf))
            | None -> Lwt.return None
          in

          Client.call
            ~headers:(Web.Request.headers req |> Web.HTTP.Headers.merge headers)
            ~body:(producer ~final:stream
                     (Encoder.encode encoder
                        (`HttpUpdateRequest { Encoder.shallow
                                            ; requests = Encoder.L (x, r)
                                            ; capabilities })))
            (Web.Request.meth req)
            (Web.Request.uri req
             |> (fun uri -> Uri.with_scheme uri (Some scheme))
             |> (fun uri -> Uri.with_host uri (Some host))
             |> (fun uri -> Uri.with_port uri port))
          >>= fun resp ->
          consume (Web.Response.body resp) (Decoder.decode decoder (Decoder.HttpReportStatus sideband)) >>= function
          | Ok { Decoder.unpack = Ok (); commands; } ->
            Lwt.return (Ok commands)
          | Ok { Decoder.unpack = Error err; _ } ->
            Lwt.return (Error (`ReportStatus err))
          | Error err -> Lwt.return (Error (`SmartDecoder err))

  let fetch git ?(shallow = []) ?stdout ?stderr ?headers ?(https = false)
      ?(capabilities=Default.capabilites)
      ~negociate:(negociate, nstate) ~has ~want ?deepen ?port host path =
    let scheme = if https then "https" else "http" in
    let uri =
      Uri.empty
      |> (fun uri -> Uri.with_scheme uri (Some scheme))
      |> (fun uri -> Uri.with_host uri (Some host))
      |> (fun uri -> Uri.with_path uri (String.concat "/" [ path; "info"; "refs" ]))
      |> (fun uri -> Uri.with_port uri port)
      |> (fun uri -> Uri.add_query_param uri ("service", [ "git-upload-pack" ]))
    in

    Log.debug (fun l -> l ~header:"fetch" "Launch the GET request to %a."
                  Uri.pp_hum uri);

    let git_agent =
      List.fold_left (fun acc -> function `Agent s -> Some s | _ -> acc)
        None capabilities
      |> function
      | Some git_agent -> git_agent
      | None -> raise (Invalid_argument "Expected an user agent in capabilities.")
    in

    let headers =
      option_map_default
        Web.HTTP.Headers.(def user_agent git_agent)
        Web.HTTP.Headers.(def user_agent git_agent empty)
        headers
    in

    Log.debug (fun l -> l ~header:"fetch" "Send the GET (reference discovery) request.");

    Client.call ~headers `GET uri >>= fun resp ->

    let decoder = Decoder.decoder () in
    let encoder = Encoder.encoder () in
    let keeper = Lwt_mvar.create has in

    consume (Web.Response.body resp) (Decoder.decode decoder (Decoder.HttpReferenceDiscovery "git-upload-pack")) >>= function
    | Error err ->
      Log.err (fun l -> l ~header:"fetch" "The HTTP decoder returns an error: %a." Decoder.pp_error err);
      Lwt.return (Error (`SmartDecoder err))
    | Ok refs ->
      let common =
        List.filter (fun x ->
            List.exists ((=) x) capabilities
          ) refs.Decoder.capabilities
      in
      let sideband =
        if List.exists ((=) `Side_band_64k) common
        then `Side_band_64k
        else if List.exists ((=) `Side_band) common
        then `Side_band
        else `No_multiplexe
      in

      let ack_mode =
        if List.exists ((=) `Multi_ack_detailed) common
        then `Multi_ack_detailed
        else if List.exists ((=) `Multi_ack) common
        then `Multi_ack
        else `Ack
      in

      Lwt_list.map_p (fun (hash, refname, peeled) -> Lwt.return (hash, Store.Reference.of_string refname, peeled)) refs.Decoder.refs
      >>= want >>= function
      | [] -> Lwt.return (Ok ([], 0))
      | first :: rest ->
        let negociation_request final has =
          Log.debug (fun l -> l ~header:"fetch" "Send a POST negociation request (done:%b): %a."
                        final (Fmt.Dump.list Store.Hash.pp) has);

          let req =
            Web.Request.v
              `POST
              ~path:[ path; "git-upload-pack" ]
              Web.HTTP.Headers.(def content_type "application/x-git-upload-pack-request" headers)
              (fun _ -> Lwt.return ())
          in

          Client.call
            ~headers:(Web.Request.headers req |> Web.HTTP.Headers.merge headers)
            ~body:(producer (Encoder.encode encoder
                               (`HttpUploadRequest (final,
                                                    { Encoder.want = snd first, List.map snd rest
                                                    ; capabilities
                                                    ; shallow
                                                    ; deep = deepen
                                                    ; has }))))
            (Web.Request.meth req)
            (Web.Request.uri req
             |> (fun uri -> Uri.with_scheme uri (Some scheme))
             |> (fun uri -> Uri.with_host uri (Some host))
             |> (fun uri -> Uri.with_port uri port))
        in

        negociation_request false has >>= fun resp ->

        Log.debug (fun l -> l ~header:"fetch" "Receiving the first negotiation response.");

        let next resp =
          consume (Web.Response.body resp)
            (Decoder.decode decoder Decoder.NegociationResult) >>= function
          | Error err -> Lwt.return (Error (`SmartDecoder err))
          | Ok _ -> (* TODO: check negociation result. *)
            let stream () = consume (Web.Response.body resp) (Decoder.decode decoder (Decoder.PACK sideband)) in
            Lwt_result.(populate ?stdout ?stderr git stream >>= fun (_, n) -> Lwt.return (Ok (first :: rest, n)))
        in

        let rec loop ~final state resp = match final with
          | true -> next resp
          | false ->
            Lwt_mvar.take keeper >>= fun has -> Lwt_mvar.put keeper has >>= fun () ->

            Log.debug (fun l -> l ~header:"fetch" "Receiving a negotiation response.");

            consume (Web.Response.body resp)
              (Decoder.decode decoder (Decoder.Negociation (has, ack_mode))) >>= function
            | Error err ->
              Lwt.return (Error (`SmartDecoder err))
            | Ok acks ->
              Log.debug (fun l -> l ~header:"fetch" "ACK response received: %a." Decoder.pp_acks acks);

              negociate acks state >>= function
              | `Ready, _ -> next resp
              | `Again has', state ->
                Lwt_mvar.take keeper >>= fun has ->
                let has = has @ has' in
                Lwt_mvar.put keeper has >>= fun () ->

                negociation_request false has >>= loop ~final:false state
              | `Done, _ -> next resp
        in

        loop ~final:(List.length has = 0) nstate resp

  let want git requested local_refs remote_refs =
    Lwt_list.filter_map_p (function
        | (remote_hash, remote_ref, false) ->
          (requested remote_ref >>= function
            | false ->
              Log.debug (fun l -> l ~header:"want" " We discard the reference %a."
                            Store.Reference.pp remote_ref);
              Lwt.return None
            | true ->
              Lwt.try_bind
                (fun () -> Lwt_list.find_s
                    (fun (local_ref, _) ->
                       Lwt.return Store.Reference.(equal local_ref remote_ref))
                    local_refs)
                (fun (_, local_hash) ->
                   Log.debug (fun l -> l ~header:"want"
                                 "The local hash of the expected reference %a \
                                  is %a and the server hash is %a."
                                 Store.Reference.pp remote_ref
                                 Store.Hash.pp local_hash
                                 Store.Hash.pp remote_hash);
                   Lwt.return (Some (remote_ref, remote_hash)))
                (fun _ ->
                   Log.debug (fun l -> l ~header:"want"
                                 "We did not find the reference %a \
                                  as an expected reference but we will probably download it."
                                 Store.Reference.pp remote_ref);

                   Lwt.return (Some (remote_ref, remote_hash)))
              >>= function
              | None -> Lwt.return None
              | Some (remote_ref, remote_hash) ->
                Store.mem git remote_hash >>= function
                | true -> Lwt.return None
                | false -> Lwt.return (Some (remote_ref, remote_hash)))
        | _ -> Lwt.return None
      ) remote_refs

  let clone_ext git ?stdout ?stderr ?headers ?(https = false) ?port
      ?(reference = Store.Reference.master) ?capabilities
      host path =
    Store.Ref.list git >>= fun local_references ->

    let want = want git
        (fun reference' ->
           Lwt.return Store.Reference.(equal reference reference'))
        local_references in

    fetch git ?stdout ?stderr ?headers ?capabilities ~https
      ~negociate:((fun _ () -> Lwt.return (`Done, ())), ())
      ~has:[]
      ~want
      ?port host path
    >>= function
    | Ok ([ _, hash ], _) -> Lwt.return (Ok hash)
    | Ok (expect, _) ->
      Lwt.return
        (Error
           (`Clone
              (Fmt.strf "Unexpected result: %a."
                 (Fmt.hvbox (Fmt.Dump.list (Fmt.Dump.pair Store.Reference.pp Store.Hash.pp)))
                 expect)))
    | Error _ as err -> Lwt.return err

  module Negociator = Git.Negociator.Make(Store)

  exception Jump of Store.Ref.error

  let clone t ?locks ?capabilities ~reference:(local_ref, remote_ref) repository =
    let host =
      Option.value_exn (Uri.host repository)
        ~error:(Fmt.strf "Expected an http url with host: %a."
                  Uri.pp_hum repository)
    in
    let https = Option.mem (Uri.scheme repository) "https" ~equal:String.equal in
    clone_ext t ~https ?port:(Uri.port repository) ?capabilities
      ~reference:remote_ref host (Uri.path_and_query repository)
    >?= fun hash' ->
      Store.Ref.write t ?locks local_ref (Store.Reference.Hash hash')
      >!= (fun err -> Lwt.return (`Ref err))
      >?= fun () ->
        Store.Ref.write t ?locks Store.Reference.head
          (Store.Reference.Ref local_ref)
        >!= (fun err -> Lwt.return (`Ref err))

  let fetch_and_update git ?locks ?capabilities ~choose ~create ~references repository =
    Negociator.find_common git >>= fun (has, state, continue) ->
    let continue { Decoder.acks; shallow; unshallow } state =
      continue { Git.Negociator.acks; shallow; unshallow } state in

    Store.Ref.list ?locks git >>=
    Lwt_list.filter_map_p
      (fun (local_ref, local_hash) ->
         Lwt.try_bind
           (fun () ->
              Lwt_list.find_s
                (fun (local_ref', _) ->
                   Lwt.return Store.Reference.(equal local_ref local_ref'))
                references)
           (fun (_, remote_ref) ->
              Lwt.return (Some (remote_ref, local_hash)))
           (fun _ -> Lwt.return None))
    >>= fun local_refs_binded_with_remote_refs ->
    let want = want git choose local_refs_binded_with_remote_refs in
    let host =
      Option.value_exn (Uri.host repository)
        ~error:(Fmt.strf "Expected an http url with host: %a."
                  Uri.pp_hum repository) in
    let https =
      Option.mem (Uri.scheme repository) "https" ~equal:String.equal in
    fetch git ~https ?port:(Uri.port repository) ?capabilities
      ~negociate:(continue, state) ~has ~want host
      (Uri.path_and_query repository)
    >?= fun (lst, _) ->
      Lwt_list.filter_map_p
        (fun (remote_ref, local_hash) ->
           Lwt.try_bind
             (fun () -> Lwt_list.find_s
                 (fun (_, expected_remote_ref) ->
                    Lwt.return Store.Reference.(equal remote_ref expected_remote_ref))
                 references)
             (fun (expected_local_ref, _) ->
                Lwt.return (Some (expected_local_ref, local_hash)))
             (fun _ -> match create remote_ref with
                | Some local_ref -> Lwt.return (Some (local_ref, local_hash))
                | None -> Lwt.return None))
        lst
      >>= fun update_lst ->
      Lwt_list.filter_map_p
        (fun (remote_ref, local_hash) ->
           Lwt.try_bind
             (fun () -> Lwt_list.find_s
                 (fun (_, expected_remote_ref) ->
                    Lwt.return Store.Reference.(equal remote_ref expected_remote_ref))
                 references)
             (fun _ -> Lwt.return None)
             (fun _ -> match create remote_ref with
                | Some _ -> Lwt.return None
                | None -> Lwt.return (Some (remote_ref, local_hash))))
        lst
      >>= fun discard_lst ->
      Lwt.catch (fun () ->
          Lwt_list.iter_s
            (fun (reference, hash) ->
               Store.Ref.write git ?locks reference (Store.Reference.Hash hash)
               >>= function
               | Ok _ -> Lwt.return ()
               | Error err -> Lwt.fail (Jump err)
            ) update_lst >>= fun () ->
          Lwt.return (Ok (update_lst, discard_lst)))
        (function
          | Jump err -> Lwt.return (Error (`Ref err))
          | exn -> Lwt.fail exn) (* XXX(dinosaure): should never happen. *)

  let fetch_all git ?locks ?capabilities ~references ?(origin = "origin") repository =
    let choose _ = Lwt.return true in
    let create remote_ref =
      match Fpath.segs (Store.Reference.to_path remote_ref) with
      | "refs" :: "heads" :: branch when List.length branch > 0 ->
        Some (Store.Reference.of_string
                (String.concat "/"
                   ([ "refs"
                    ; "remotes"
                    ; origin ] @ branch)))
      | _ -> None
    in
    fetch_and_update
      ~choose
      ~create
      ?locks
      ?capabilities
      ~references
      git repository

  let fetch_some git ?locks ?capabilities ~references repository =
    let choose remote_ref =
      Lwt_list.exists_p
        (fun (_, expected_remote_ref) ->
           Lwt.return Store.Reference.(equal remote_ref expected_remote_ref))
        references
    in
    let create _ = None in
    fetch_and_update
      ~choose
      ~create
      ?locks
      ?capabilities
      ~references
      git repository
    >?= function
      | [] -> Lwt.return (Ok ())
      | discard ->
        Log.err (fun l -> l ~header:"fetch_some"
                    "We discard some server-side references: %a."
                    Fmt.(hvbox (Dump.list (Dump.pair Store.Reference.pp Store.Hash.pp)))
                    discard);
        Lwt.return (Ok ()) (* XXX(dinosaure): should return an error? *)

  let fetch_one git ?locks ?capabilities ~reference:((_, expected_remote_ref) as reference) repository =
    let choose remote_ref =
      Lwt.return Store.Reference.(equal remote_ref expected_remote_ref) in
    let create _ = None in
    fetch_and_update
      ~choose
      ~create
      ?locks
      ?capabilities
      ~references:[ reference ]
      git repository
    >?= function
      | [] -> Lwt.return (Ok ())
      | discard ->
        Log.err (fun l -> l ~header:"fetch_one"
                    "We discard some server-side references: %a."
                    Fmt.(hvbox (Dump.list (Dump.pair Store.Reference.pp Store.Hash.pp)))
                    discard);
        Lwt.return (Ok ()) (* XXX(dinosaure): should return an error? *)

  let update t ?capabilities ~reference repository =
    let push_handler git remote_refs =
      Store.Ref.list git >>=
      Lwt_list.find_s (fun (reference', _) ->
          Lwt.return Store.Reference.(equal reference reference')
        ) >>= fun (_, local_hash) ->
      Lwt_list.find_s (function
          | (_, reference', false) ->
            Lwt.return Store.Reference.(equal reference reference')
          | (_, _, true) -> Lwt.return false
        ) remote_refs >|= fun (remote_hash, remote_reference, _) ->
      if Store.Hash.equal local_hash remote_hash
      then ([], [])
      else ([], [ `Update (remote_hash, local_hash, remote_reference) ])
    in
    let host =
      Option.value_exn (Uri.host repository)
        ~error:(Fmt.strf "Expected an http url with host: %a."
                  Uri.pp_hum repository)
    in
    let https =
      Option.mem (Uri.scheme repository) "https" ~equal:String.equal
    in
    push t ~push:push_handler ~https ?capabilities ?port:(Uri.port repository)
      host (Uri.path_and_query repository)
    >?= fun lst ->
      Lwt_result.ok (Lwt_list.map_p (function
          | Ok refname -> Lwt.return (Ok (Store.Reference.of_string refname))
          | Error (refname, err) ->
            Lwt.return (Error (Store.Reference.of_string refname, err))
        ) lst)

end

module Make
    (C: CLIENT
     with type +'a io = 'a Lwt.t
      and type headers = Web_cohttp_lwt.HTTP.headers
      and type body = Lwt_cstruct_flow.o
      and type meth = Web_cohttp_lwt.HTTP.meth
      and type uri = Web_cohttp_lwt.uri
      and type resp = Web_cohttp_lwt.resp)
    (S: Git.S)
  = Make_ext(Web_cohttp_lwt)(C)(S)
