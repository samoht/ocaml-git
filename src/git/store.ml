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

let ( >>!= ) x f = Lwt_result.map_err f x
let ( >>?= ) = Lwt_result.bind
let src = Logs.Src.create "git.store" ~doc:"logs git's store event"

module Log = (val Logs.src_log src : Logs.LOG)

(* XXX(samoht): duplicate of Loose.S? *)
module type LOOSE = sig
  type t
  type state
  type error
  type kind = [`Commit | `Tree | `Tag | `Blob]

  module FS : S.FS
  module Hash : S.HASH
  module Inflate : S.INFLATE
  module Deflate : S.DEFLATE

  module Value :
    Value.S
    with module Hash := Hash
     and module Inflate := Inflate
     and module Deflate := Deflate
     and module Blob = Blob.Make(Hash)
     and module Commit = Commit.Make(Hash)
     and module Tree = Tree.Make(Hash)
     and module Tag = Tag.Make(Hash)
     and type t = Value.Make(Hash)(Inflate)(Deflate).t

  val mem : state -> Hash.t -> bool Lwt.t
  val list : state -> Hash.t list Lwt.t
  val read : state -> Hash.t -> (t, error) result Lwt.t
  val size : state -> Hash.t -> (int64, error) result Lwt.t
  val write : state -> t -> (Hash.t * int, error) result Lwt.t
  val write_inflated : state -> kind:kind -> Cstruct.t -> Hash.t Lwt.t
  val read_inflated : state -> Hash.t -> (kind * Cstruct.t, error) result Lwt.t

  val read_inflated_wa :
    Cstruct.t -> state -> Hash.t -> (kind * Cstruct.t, error) result Lwt.t

  module D :
    S.DECODER
    with type t = t
     and type init = Inflate.window * Cstruct.t * Cstruct.t
     and type error = [Error.Decoder.t | `Inflate of Inflate.error]

  module E :
    S.ENCODER
    with type t = t
     and type init = int * t * int * Cstruct.t
     and type error = [`Deflate of Deflate.error]
end

(* XXX(samoht): duplicate of pack?.S ? *)
module type PACK = sig
  type t
  type value
  type state
  type error

  module FS : S.FS
  module Hash : S.HASH
  module Inflate : S.INFLATE
  module Deflate : S.DEFLATE
  module HDec : Unpack.H with module Hash := Hash

  module PDec :
    Unpack.P
    with module Hash := Hash
     and module Inflate := Inflate
     and module Hunk := HDec

  module RPDec :
    Unpack.D
    with module Hash := Hash
     and module Inflate := Inflate
     and module Hunk := HDec
     and module Pack := PDec
     and module Mapper := FS.Mapper

  module PEnc : Pack.P with module Hash := Hash and module Deflate := Deflate
  module IDec : Index_pack.LAZY with module Hash := Hash
  module IEnc : Index_pack.ENCODER with module Hash := Hash

  module PInfo :
    Pack_info.S
    with module Hash := Hash
     and module Inflate := Inflate
     and module HDec := HDec
     and module PDec := PDec

  val lookup : state -> Hash.t -> (Hash.t * (Crc32.t * int64)) option Lwt.t
  val mem : state -> Hash.t -> bool Lwt.t
  val list : state -> Hash.t list Lwt.t
  val read : state -> Hash.t -> (value, error) result Lwt.t
  val size : state -> Hash.t -> (int, error) result Lwt.t

  type stream = unit -> Cstruct.t option Lwt.t

  val from : state -> stream -> (Hash.t * int, error) result Lwt.t

  val make :
       state
    -> ?window:[`Object of int | `Memory of int]
    -> ?depth:int
    -> value list
    -> (stream * (Crc32.t * int64) Hash.Map.t Lwt_mvar.t, error) result Lwt.t
end

module type S = sig
  type t

  module FS : S.FS
  module Hash : S.HASH
  module Inflate : S.INFLATE
  module Deflate : S.DEFLATE

  module Value :
    Value.S
    with module Hash := Hash
     and module Inflate := Inflate
     and module Deflate := Deflate
     and module Blob = Blob.Make(Hash)
     and module Commit = Commit.Make(Hash)
     and module Tree = Tree.Make(Hash)
     and module Tag = Tag.Make(Hash)
     and type t = Value.Make(Hash)(Inflate)(Deflate).t

  module Reference : Reference.IO with module Hash := Hash and module FS := FS
  module HDec : Unpack.H with module Hash := Hash

  module PDec :
    Unpack.P
    with module Hash := Hash
     and module Inflate := Inflate
     and module Hunk := HDec

  module RPDec :
    Unpack.D
    with module Hash := Hash
     and module Inflate := Inflate
     and module Hunk := HDec
     and module Pack := PDec
     and module Mapper := FS.Mapper

  module PEnc : Pack.P with module Hash := Hash and module Deflate := Deflate
  module IDec : Index_pack.LAZY with module Hash := Hash
  module IEnc : Index_pack.ENCODER with module Hash := Hash

  module PInfo :
    Pack_info.S
    with module Hash := Hash
     and module Inflate := Inflate
     and module HDec := HDec
     and module PDec := PDec

  module Packed_refs :
    Packed_refs.S with module Hash := Hash and module FS := FS

  type error =
    [ `Delta of PEnc.Delta.error
    | `Pack_decoder of RPDec.error
    | `Pack_encoder of PEnc.error
    | `Pack_info of PInfo.error
    | `Idx_decoder of IDec.error
    | `Idx_encoder of IEnc.error
    | `Invalid_hash of Hash.t
    | `Invalid_reference of Reference.t
    | Error.Decoder.t
    | FS.error Error.FS.t
    | Inflate.error Error.Inf.t
    | Deflate.error Error.Def.t
    | Error.not_found ]

  val pp_error : error Fmt.t

  module Loose :
    LOOSE
    with type t = Value.t
     and type state = t
     and type error = error
     and module Hash := Hash
     and module Inflate := Inflate
     and module Deflate := Deflate
     and module FS := FS

  module Pack :
    PACK
    with type t = RPDec.Object.t
     and type value = Value.t
     and type state = t
     and type error = error
     and module Hash := Hash
     and module FS := FS
     and module Inflate := Inflate
     and module HDec := HDec
     and module PDec := PDec
     and module RPDec := RPDec

  type kind = [`Commit | `Tree | `Tag | `Blob]
  type buffer

  val default_buffer : unit -> buffer

  val buffer :
       ?ztmp:Cstruct.t
    -> ?dtmp:Cstruct.t
    -> ?raw:Cstruct.t
    -> ?window:Inflate.window
    -> unit
    -> buffer

  val dotgit : t -> Fpath.t
  val root : t -> Fpath.t
  val compression : t -> int
  val mem : t -> Hash.t -> bool Lwt.t
  val list : t -> Hash.t list Lwt.t
  val read : t -> Hash.t -> (Value.t, error) result Lwt.t
  val read_exn : t -> Hash.t -> Value.t Lwt.t
  val write : t -> Value.t -> (Hash.t * int, error) result Lwt.t
  val size : t -> Hash.t -> (int64, error) result Lwt.t
  val read_inflated : t -> Hash.t -> (kind * Cstruct.t) option Lwt.t
  val write_inflated : t -> kind:kind -> Cstruct.t -> Hash.t Lwt.t
  val contents : t -> ((Hash.t * Value.t) list, error) result Lwt.t

  val fold :
       t
    -> ('a -> ?name:Fpath.t -> length:int64 -> Hash.t -> Value.t -> 'a Lwt.t)
    -> path:Fpath.t
    -> 'a
    -> Hash.t
    -> 'a Lwt.t

  val iter : t -> (Hash.t -> Value.t -> unit Lwt.t) -> Hash.t -> unit Lwt.t

  module Ref : sig
    val mem : t -> Reference.t -> bool Lwt.t
    val graph : t -> (Hash.t Reference.Map.t, error) result Lwt.t

    val normalize :
         Hash.t Reference.Map.t
      -> Reference.head_contents
      -> (Hash.t, error) result Lwt.t

    val list : t -> (Reference.t * Hash.t) list Lwt.t
    val remove : t -> Reference.t -> (unit, error) result Lwt.t

    val read :
      t -> Reference.t -> (Reference.head_contents, error) result Lwt.t

    val resolve : t -> Reference.t -> (Hash.t, error) result Lwt.t

    val write :
      t -> Reference.t -> Reference.head_contents -> (unit, error) result Lwt.t
  end

  val clear_caches : t -> unit Lwt.t
  val reset : t -> (unit, error) result Lwt.t
  val has_global_watches : bool
  val has_global_checkout : bool
end

module Make (H : Digestif.S) (FS : S.FS) (I : S.INFLATE) (D : S.DEFLATE) =
struct
  module Hash = Hash.Make (H)
  module Inflate = I
  module Deflate = D
  module FS = FS

  let has_global_watches = FS.has_global_watches
  let has_global_checkout = FS.has_global_checkout

  module LooseImpl = Loose.Make (Hash) (FS) (Inflate) (Deflate)
  module HDec = Unpack.Hunk (Hash)
  module PDec = Unpack.Pack (Hash) (Inflate) (HDec)
  module RPDec = Unpack.Decoder (Hash) (FS.Mapper) (Inflate) (HDec) (PDec)
  module PackImpl = Pack_engine.Make (Hash) (FS) (I) (D) (HDec) (PDec) (RPDec)
  module Value = Value.Make (Hash) (Inflate) (Deflate)
  module PEnc = PackImpl.PEnc
  module IDec = PackImpl.IDec
  module IEnc = PackImpl.IEnc
  module PInfo = PackImpl.PInfo
  module Packed_refs = Packed_refs.Make (Hash) (FS)
  module Reference = Reference.IO (Hash) (FS)

  module DoubleHash = struct
    type t = Hash.t * Hash.t

    let hash = Hashtbl.hash
    let equal (a, b) (c, d) = Hash.equal a c && Hash.equal b d
  end

  module HashInt64 = struct
    type t = Hash.t * int64

    let hash = Hashtbl.hash
    let equal (a, b) (c, d) = Hash.equal a c && Int64.equal b d
  end

  (* XXX(dinosaure): need to limit the weight of [CacheObject] and [CacheValue]
     by the memory consumption of the data stored - and not by the number of
     theses data. Indeed, 5 commits is more cheaper than 1 blob sometimes. *)
  module CacheObject =
    Lru.M.Make
      (DoubleHash)
      (struct
        type t = RPDec.Object.t

        let weight _ = 1
      end)

  module H = struct
    type t = Hash.t

    let hash = Hashtbl.hash
    let equal x y = Hash.unsafe_compare x y = 0
  end

  module CacheValue =
    Lru.M.Make (H) (struct type t = Value.t

                           let weight _ = 1 end)

  module CachePack =
    Lru.M.Make (H) (struct type t = PDec.t

                           let weight _ = 1 end)

  (* fixed size *)

  module CacheIndex =
    Lru.M.Make
      (H)
      (* not fixed size by consider than it's ok. *)
      (struct
        type t = IDec.t

        let weight _ = 1
      end)

  module CacheRevIndex =
    Lru.M.Make (HashInt64) (struct type t = Hash.t

                                   let weight _ = 1 end)

  (* fixed size *)

  type buffer =
    {window: Inflate.window; raw: Cstruct.t; ztmp: Cstruct.t; dtmp: Cstruct.t}

  type cache =
    { objects: CacheObject.t
    ; values: CacheValue.t
    ; packs: CachePack.t
    ; indexes: CacheIndex.t
    ; revindexes: CacheRevIndex.t }

  type lock = No_lock | Lock of Lwt_mutex.t

  type t =
    { fs: FS.t
    ; dotgit: Fpath.t
    ; root: Fpath.t
    ; allocation:
        ((Hash.t, Cstruct.t Lwt_pool.t * int) Hashtbl.t, lock) PackImpl.r
    ; compression: int
    ; cache: cache
    ; buffer: (buffer -> unit Lwt.t) -> unit Lwt.t
    ; packed: (Reference.t, Hash.t) Hashtbl.t
    ; engine: PackImpl.t }

  type error =
    [ PackImpl.error
    | `Delta of PEnc.Delta.error
    | Error.Decoder.t
    | FS.error Error.FS.t
    | Inflate.error Error.Inf.t
    | Deflate.error Error.Def.t
    | `Invalid_reference of Reference.t ]

  let pp_error ppf = function
    | #LooseImpl.error as err -> Fmt.pf ppf "%a" LooseImpl.pp_error err
    | #PackImpl.error as err -> Fmt.pf ppf "%a" PackImpl.pp_error err
    | `Invalid_reference reference ->
        Fmt.pf ppf "Invalid reference: %a" Reference.pp reference

  let lift_error err = (err :> error)
  let new_buffer = function Some b -> b | None -> Cstruct.create (4 * 1024)
  let new_window = function Some w -> w | None -> Inflate.window ()

  let buffer ?ztmp ?dtmp ?raw ?window () =
    let window = new_window window in
    let ztmp = new_buffer ztmp in
    let dtmp = new_buffer dtmp in
    let raw = new_buffer raw in
    {window; ztmp; dtmp; raw}

  let with_buffer t f =
    let c = ref None in
    t.buffer (fun buf -> f buf >|= fun x -> c := Some x)
    >|= fun () -> match !c with Some x -> x | None -> assert false

  module Loose = struct
    module Hash = Hash
    module FS = FS
    module Inflate = Inflate
    module Deflate = Deflate
    module Value = Value

    type state = t
    type t = LooseImpl.t
    type nonrec error = error
    type kind = LooseImpl.kind

    let read t path =
      with_buffer t
      @@ fun {ztmp; dtmp; raw; window} ->
      LooseImpl.read ~fs:t.fs ~root:t.dotgit ~window ~ztmp ~dtmp ~raw path
      >>!= lift_error

    let size t path =
      with_buffer t
      @@ fun {ztmp; dtmp; raw; window} ->
      LooseImpl.size ~fs:t.fs ~root:t.dotgit ~window ~ztmp ~dtmp ~raw path
      >>!= lift_error

    let write t value =
      with_buffer t
      @@ fun {ztmp; raw; _} ->
      LooseImpl.write ~fs:t.fs ~root:t.dotgit ~ztmp ~raw ~level:t.compression
        value
      >>!= lift_error

    let mem t = LooseImpl.mem ~fs:t.fs ~root:t.dotgit
    let list t = LooseImpl.list ~fs:t.fs ~root:t.dotgit

    let read_inflated t hash =
      with_buffer t
      @@ fun {ztmp; dtmp; raw; window} ->
      LooseImpl.inflate ~fs:t.fs ~root:t.dotgit ~window ~ztmp ~dtmp ~raw hash
      >>!= lift_error

    let read_inflated_wa result t hash =
      with_buffer t
      @@ fun {ztmp; dtmp; raw; window} ->
      LooseImpl.inflate_wa ~fs:t.fs ~root:t.dotgit ~window ~ztmp ~dtmp ~raw
        ~result hash
      >>!= lift_error

    let write_inflated t ~kind value =
      with_buffer t
      @@ fun {raw; _} ->
      LooseImpl.write_inflated ~fs:t.fs ~root:t.dotgit ~level:t.compression
        ~raw ~kind value
      >>= function
      | Ok hash -> Lwt.return hash
      | Error e -> Fmt.kstrf Lwt.fail_with "%a" LooseImpl.pp_error e

    module D = Value.D
    module E = Value.E
  end

  module Pack = struct
    module Hash = Hash
    module FS = Helper.FS (FS)
    module Inflate = Inflate
    module Deflate = Deflate
    module HDec = HDec
    module PDec = PDec
    module IEnc = PackImpl.IEnc
    module IDec = PackImpl.IDec
    module PEnc = PackImpl.PEnc
    module PInfo = PackImpl.PInfo
    module RPDec = RPDec

    type state = t
    type t = RPDec.Object.t
    type value = Value.t
    type nonrec error = error

    let default n =
      let heap = Hashtbl.create 32 in
      let mutex = Lwt_mutex.create () in
      let buffer = ref (Cstruct.create 0x8000) in
      let round len nlen =
        let ilen = ref len in
        while nlen > !ilen do
          ilen := 2 * !ilen
        done ;
        !ilen
      in
      let fit length =
        if length > Cstruct.len !buffer then (
          let diff =
            round (Cstruct.len !buffer) length - Cstruct.len !buffer
          in
          buffer := Cstruct.concat [!buffer; Cstruct.create diff] ;
          Cstruct.sub !buffer 0 length )
        else Cstruct.sub !buffer 0 length
      in
      let with_cstruct heap pack length (exec : lock * Cstruct.t -> unit Lwt.t)
          =
        match pack with
        | PackImpl.Unrecorded ->
            Lwt_mutex.lock mutex >>= fun () -> exec (Lock mutex, fit length)
        | Pack hash_pack -> (
          match Hashtbl.find heap hash_pack with
          | pool, length' ->
              assert (length = length') ;
              Lwt_pool.use pool (fun buffer -> exec (No_lock, buffer))
          | exception Not_found ->
              let pool =
                Lwt_pool.create n (fun () -> Lwt.return (Cstruct.create length))
              in
              Hashtbl.add heap hash_pack (pool, length) ;
              Lwt_pool.use pool (fun buffer -> exec (No_lock, buffer)) )
      in
      let free _ = function
        | Lock mutex' ->
            assert (mutex == mutex') ;
            Lwt_mutex.unlock mutex ;
            Lwt.return_unit
        | No_lock -> Lwt.return_unit
      in
      {PackImpl.mmu= heap; with_cstruct; free}

    let to_result (kind, raw, _, _) =
      let open Rresult in
      ( match kind with
      | `Commit -> Value.(Commit.D.to_result raw >>| commit)
      | `Blob -> Value.(Blob.D.to_result raw >>| blob)
      | `Tree -> Value.(Tree.D.to_result raw >>| tree)
      | `Tag -> Value.(Tag.D.to_result raw >>| tag) )
      |> Rresult.R.reword_error (fun err -> (err :> PackImpl.error))
      |> Lwt.return

    let read_loose t hash =
      Loose.read_inflated t hash
      >|= function
      | Ok v -> Some v
      | Error err ->
          Log.err (fun l ->
              l
                "Retrieve an error when a PACK file expect an external loose \
                 object %a: %a."
                Hash.pp hash pp_error err ) ;
          None

    let lookup t hash = PackImpl.lookup t.engine hash |> Lwt.return
    let mem t hash = PackImpl.mem t.engine hash |> Lwt.return
    let list t = PackImpl.list t.engine |> Lwt.return

    let read t hash =
      mem t hash
      >>= function
      | false -> Lwt.return (Error `Not_found)
      | true ->
          with_buffer t
          @@ fun {ztmp; window; _} ->
          Log.debug (fun l ->
              l "Git object %a found in a PACK file." Hash.pp hash ) ;
          PackImpl.read ~root:t.dotgit ~read_loose:(read_loose t) ~to_result
            ~ztmp ~window t.fs t.allocation t.engine hash
          >>!= lift_error

    let to_result (kind, raw, _, _) =
      let cstruct_copy cs =
        let ln = Cstruct.len cs in
        let rs = Cstruct.create ln in
        Cstruct.blit cs 0 rs 0 ln ; rs
      in
      Lwt.return_ok (kind, cstruct_copy raw)

    let read_inflated t hash =
      mem t hash
      >>= function
      | false -> Lwt.return (Error `Not_found)
      | true ->
          with_buffer t
          @@ fun {ztmp; window; _} ->
          Log.debug (fun l ->
              l "Git object %a found in a PACK file." Hash.pp hash ) ;
          PackImpl.read ~root:t.dotgit ~read_loose:(read_loose t) ~to_result
            ~ztmp ~window t.fs t.allocation t.engine hash
          >>!= lift_error

    let size t hash =
      mem t hash
      >>= function
      | false -> Lwt.return (Error `Not_found)
      | true ->
          with_buffer t
          @@ fun {ztmp; window; _} ->
          PackImpl.size ~root:t.dotgit ~read_loose:(read_loose t) ~ztmp ~window
            t.fs t.engine hash
          >>!= lift_error

    type stream = unit -> Cstruct.t option Lwt.t

    let random_string len =
      let gen () =
        match Random.int (26 + 26 + 10) with
        | n when n < 26 -> int_of_char 'a' + n
        | n when n < 26 + 26 -> int_of_char 'A' + n - 26
        | n -> int_of_char '0' + n - 26 - 26
      in
      let gen () = char_of_int (gen ()) in
      Bytes.create len
      |> fun raw ->
      for i = 0 to len - 1 do
        Bytes.set raw i (gen ())
      done ;
      Bytes.unsafe_to_string raw

    exception Save of error

    let to_temp_file ?(limit = 50) fs ~temp_dir fmt stream =
      let filename_of_pack = fmt (random_string 10) in
      let path = Fpath.(temp_dir / filename_of_pack) in
      FS.File.open_w fs path
      >|= Rresult.R.reword_error (fun err -> Error.FS.err_open path err)
      >>?= fun fd ->
      Log.debug (fun l -> l "Saving pack stream to %a." Fpath.pp path) ;
      let chunk = ref None in
      let call = ref 0 in
      let closed = ref false in
      let close msg =
        Log.debug (fun l -> l "XXX close %a: %s" Fpath.pp path msg);
        if !closed then Lwt.return ()
        else (
          FS.File.close fd
          >>= function
          | Error err ->
            Log.debug (fun l -> l "XXX can't close");
            Lwt.fail (Save Error.(FS.err_close path err))
          | Ok ()     ->
            closed := true;
            Lwt.return ())
      in
      let stream () =
        Lwt_stream.peek stream
        >>= function
        | None -> close "peek" >|= fun () -> None
        | Some raw -> (
            let off, len =
              match !chunk with
              | Some (off, len) -> off, len
              | None -> 0, Cstruct.len raw
            in
            FS.File.write raw ~off ~len fd
            >>= function
            | Error err ->
                close "write" >>= fun () ->
                Lwt.fail (Save Error.(FS.err_write path err))
            | Ok 0 when !call = limit ->
                close "limit" >>= fun () ->
                Lwt.fail (Save Error.(FS.err_stack path))
            | Ok 0 ->
                incr call ;
                Lwt.return_some (Cstruct.sub raw off 0)
            | Ok n ->
                if n = len then
                  Lwt_stream.junk stream >|= fun () ->
                  Some (Cstruct.sub raw off n)
                else (
                  chunk := Some (off + n, len - n) ;
                  Lwt.return_some (Cstruct.sub raw off n) ) )
      in
      Lwt.return_ok (path, stream)

    let extern t hash =
      read_inflated t hash
      >>= function
      | Ok v -> Lwt.return_some v
      | Error _ -> (
          Loose.mem t hash
          >>= function
          | false -> Lwt.return_none
          | true -> (
              Loose.read_inflated t hash
              >>= function
              | Error _ -> Lwt.return_none | Ok v -> Lwt.return_some v ) )

    module GC = Collector.Make (struct
      module Hash = Hash
      module Inflate = Inflate
      module Deflate = Deflate
      module Value = Value
      module PEnc = PEnc

      type nonrec t = state
      type nonrec error = error
      type kind = RPDec.kind

      let pp_error = pp_error
      let read_inflated = extern
      let contents _ = assert false
    end)

    let make = GC.make_stream

    let from t stream =
      Lwt.catch
        (fun () ->
          let stream = Lwt_stream.from stream in
          let temp_dir = Fpath.(t.dotgit / "tmp") in
          to_temp_file t.fs (Fmt.strf "pack-%s.pack") ~temp_dir stream
          >>?= fun (path_tmp, stream) ->
          with_buffer t
          @@ fun {ztmp; window; _} ->
          PInfo.first_pass ~ztmp ~window stream
          >>!= (fun err -> `Pack_info err)
          >>?= fun info ->
          stream () >>= fun b ->
          Log.debug (fun l -> l "XXX 42 %b" (b = None));
          PackImpl.add ~root:t.dotgit ~read_loose:(read_loose t) ~ztmp ~window
            t.fs t.allocation t.engine path_tmp info
          >>!= lift_error )
        (function Save err -> Lwt.return_error err | exn -> Lwt.fail exn)
  end

  type kind = [`Commit | `Blob | `Tree | `Tag]

  let read state hash =
    Log.debug (fun l -> l "read %a" Hash.pp hash) ;
    Pack.read state hash
    >>= function
    | Ok _ as v -> Lwt.return v
    | Error err -> (
        Loose.mem state hash
        >>= function
        | false -> Lwt.return (Error err)
        | true -> (
            Loose.read state hash
            >|= function Error e -> Error (e :> error) | Ok v -> Ok v ) )

  let read_exn t hash =
    read t hash
    >>= function
    | Ok v -> Lwt.return v
    | Error _ ->
        let err = Fmt.strf "Git.Store.read_exn: %a not found" Hash.pp hash in
        Lwt.fail_invalid_arg err

  let write state hash =
    Loose.write state hash
    >|= function Error e -> Error (e :> error) | Ok v -> Ok v

  let read_inflated state hash =
    Pack.read_inflated state hash
    >>= function
    | Ok v -> Lwt.return_some v
    | Error _ -> (
        Loose.mem state hash
        >>= function
        | false -> Lwt.return_none
        | true -> (
            Loose.read_inflated state hash
            >|= function Error _ -> None | Ok v -> Some v ) )

  let write_inflated t ~kind value = Loose.write_inflated t ~kind value

  let indexes ~fs git =
    FS.Dir.contents fs ~rel:false Fpath.(git / "objects" / "pack")
    >>= function
    | Error err -> Lwt.return Error.(v @@ FS.err_sys_dir err)
    | Ok lst ->
        let idx =
          List.fold_left
            (fun acc path ->
              if Fpath.has_ext "idx" path then path :: acc else acc )
            [] lst
        in
        PackImpl.v fs idx >|= fun v -> Ok v

  let lookup state hash =
    Pack.lookup state hash
    >>= function
    | Some (hash_pack, (_, offset)) ->
        Lwt.return (`Pack_decoder (hash_pack, offset))
    | None -> (
        Loose.mem state hash
        >|= function true -> `Loose | false -> `Not_found )

  let mem state hash =
    lookup state hash >|= function `Not_found -> false | _ -> true

  let list state =
    Loose.list state
    >>= fun looses ->
    Pack.list state >|= fun packed -> List.append looses packed

  let size state hash =
    Pack.size state hash
    >>= function
    | Ok v -> Lwt.return (Ok (Int64.of_int v))
    | Error err -> (
        Loose.mem state hash
        >>= function
        | false -> Lwt.return (Error (err :> error))
        | true ->
            Loose.size state hash
            >|= Rresult.R.reword_error (fun x -> (x :> error)) )

  exception Leave of error

  let contents state =
    list state
    >>= fun lst ->
    Lwt.try_bind
      (fun () ->
        Lwt_list.map_s
          (fun hash ->
            Log.debug (fun l ->
                l ~header:"contents" "Try to read the object: %a." Hash.pp hash
            ) ;
            read state hash
            >>= function
            | Ok v -> Lwt.return (hash, v)
            | Error err ->
                Log.err (fun l ->
                    l ~header:"contents" "Retrieve an error: %a." pp_error err
                ) ;
                Lwt.fail (Leave err) )
          lst )
      (fun lst -> Lwt.return (Ok lst))
      (function Leave err -> Lwt.return (Error err) | exn -> Lwt.fail exn)

  module T = Traverse_bfs.Make (struct
    module Hash = Hash
    module Inflate = Inflate
    module Deflate = Deflate
    module Value = Value

    type nonrec t = t
    type nonrec error = error

    let pp_error = pp_error
    let read = read
  end)

  let fold = T.fold
  let iter = T.iter

  module Ref = struct
    let contents ~fs top =
      let rec lookup acc dir =
        FS.Dir.contents fs ~rel:true Fpath.(top // dir)
        >>?= fun l ->
        Lwt_list.filter_p
          (fun x ->
            FS.is_dir fs Fpath.(top // dir // x)
            >|= function Ok v -> v | Error _ -> false )
          l
        >>= fun dirs ->
        Lwt_list.filter_p
          (fun x ->
            FS.is_file fs Fpath.(top // dir // x)
            >|= function Ok v -> v | Error _ -> false )
          l
        >>= fun files ->
        let files = List.map (fun file -> Fpath.append dir file) files in
        Lwt_list.fold_left_s
          (function
            | Ok acc -> fun x -> lookup acc Fpath.(dir // x)
            | Error _ as e -> fun _ -> Lwt.return e)
          (Ok acc) dirs
        >>?= fun acc -> Lwt.return (Ok (acc @ files))
      in
      lookup [] (Fpath.v ".")

    module Graph = Reference.Map

    (* XXX(dinosaure): this function does not return any {!Error} value. *)
    let graph t =
      Log.debug (fun l -> l "graph_p") ;
      contents ~fs:t.fs Fpath.(t.dotgit / "refs")
      >>= function
      | Error err -> Lwt.return Error.(v @@ FS.err_sys_dir err)
      | Ok files -> (
          Log.debug (fun l ->
              let pp_files = Fmt.hvbox (Fmt.list Fpath.pp) in
              l "contents files: %a." pp_files files ) ;
          Lwt_list.fold_left_s
            (fun acc abs_ref ->
              (* XXX(dinosaure): we already normalize the reference (which is
                 absolute). so we consider than the root as [/]. *)
              let r = Reference.of_path abs_ref in
              with_buffer t
              @@ fun {dtmp; raw; _} ->
              Reference.read ~fs:t.fs ~root:t.dotgit r ~dtmp ~raw
              >|= function
              | Ok v -> v :: acc
              | Error err ->
                  Log.err (fun l ->
                      l "Error while reading %a: %a." Reference.pp r
                        Reference.pp_error err ) ;
                  acc )
            []
            (Reference.(to_path head) :: files)
          >>= fun lst ->
          let partial, graph =
            List.fold_left
              (fun (rest, graph) -> function
                | r, Reference.Hash hash -> rest, Graph.add r hash graph
                | r, Reference.Ref link ->
                    Log.debug (fun l ->
                        l "adding ref %a -> %a as a partial value."
                          Reference.pp r Reference.pp link ) ;
                    (r, link) :: rest, graph )
              ([], Graph.empty) lst
          in
          with_buffer t (fun {dtmp; raw; _} ->
              Packed_refs.read ~fs:t.fs ~root:t.dotgit ~dtmp ~raw )
          >>= (function
                | Error _ as err -> Lwt.return err
                | Ok packed_refs ->
                    Hashtbl.reset t.packed ;
                    List.iter
                      (function
                        | `Peeled _ -> ()
                        | `Ref (refname, hash) ->
                            Hashtbl.add t.packed
                              (Reference.of_string refname)
                              hash)
                      packed_refs ;
                    Lwt.return (Ok packed_refs))
          >|= function
          | Ok packed_refs ->
              let graph =
                List.fold_left
                  (fun graph -> function `Peeled _ -> graph
                    | `Ref (r, hash) ->
                        Graph.add (Reference.of_string r) hash graph )
                  graph packed_refs
              in
              let graph =
                List.fold_left
                  (fun graph (refname, link) ->
                    Log.debug (fun l ->
                        l "Resolving the reference %a -> %a." Reference.pp
                          refname Reference.pp link ) ;
                    try
                      let hash = Graph.find link graph in
                      Graph.add refname hash graph
                    with Not_found -> graph )
                  graph partial
              in
              Ok graph
          | Error #Packed_refs.error ->
              let graph =
                List.fold_left
                  (fun graph (refname, link) ->
                    Log.debug (fun l ->
                        l "Resolving the reference %a -> %a." Reference.pp
                          refname Reference.pp link ) ;
                    try
                      let hash = Graph.find link graph in
                      Graph.add refname hash graph
                    with Not_found -> graph )
                  graph partial
              in
              Ok graph )

    let normalize graph = function
      | Reference.Hash hash -> Lwt.return (Ok hash)
      | Reference.Ref refname -> (
        try Lwt.return (Ok (Graph.find refname graph)) with Not_found ->
          Lwt.return (Error (`Invalid_reference refname)) )

    let list t =
      graph t
      >|= function
      | Ok graph ->
          Graph.fold (fun refname hash acc -> (refname, hash) :: acc) graph []
          |> List.stable_sort (fun (a, _) (b, _) -> Reference.compare a b)
      | Error _ -> []

    let mem t reference =
      let in_packed_refs () = Hashtbl.mem t.packed reference in
      Reference.mem ~fs:t.fs ~root:t.dotgit reference
      >|= function true -> true | false -> in_packed_refs ()

    let remove t reference =
      with_buffer t (fun {dtmp; raw; _} ->
          Packed_refs.read ~fs:t.fs ~root:t.dotgit ~dtmp ~raw )
      >>= (function
            | Error _ -> Lwt.return None
            | Ok packed_refs -> (
                Lwt_list.exists_p
                  (function
                    | `Peeled _ -> Lwt.return false
                    | `Ref (refname, _) ->
                        Lwt.return
                          Reference.(equal (of_string refname) reference))
                  packed_refs
                >>= function
                | false -> Lwt.return None
                | true ->
                    Lwt_list.fold_left_s
                      (fun acc -> function
                        | `Peeled hash -> Lwt.return (`Peeled hash :: acc)
                        | `Ref (refname, hash)
                          when not
                                 Reference.(
                                   equal (of_string refname) reference) ->
                            Lwt.return (`Ref (refname, hash) :: acc)
                        | _ -> Lwt.return acc )
                      [] packed_refs
                    >|= fun packed_refs' -> Some packed_refs' ))
      >>= (function
            | None -> Lwt.return (Ok ())
            | Some packed_refs' -> (
                let temp_dir = Fpath.(t.dotgit / "tmp") in
                with_buffer t (fun {raw; _} ->
                    Packed_refs.write ~fs:t.fs ~root:t.dotgit ~temp_dir ~raw
                      packed_refs' )
                >|= function Ok () -> Ok () | Error e -> Error (e :> error) ))
      >>= function
      | Error _ as err -> Lwt.return err
      | Ok () -> (
          Reference.remove ~fs:t.fs ~root:t.dotgit reference
          >|= function Ok () -> Ok () | Error e -> Error (e :> error) )

    let read t reference =
      FS.is_file t.fs Fpath.(t.dotgit // Reference.to_path reference)
      >>= function
      | Ok true -> (
          with_buffer t
          @@ fun {dtmp; raw; _} ->
          Reference.read ~fs:t.fs ~root:t.dotgit ~dtmp ~raw reference
          >|= function Ok (_, v) -> Ok v | Error e -> Error (e :> error) )
      | Ok false | Error _ ->
          let v =
            if Hashtbl.mem t.packed reference then
              try Ok (Reference.Hash (Hashtbl.find t.packed reference))
              with Not_found -> Error `Not_found
            else Error `Not_found
          in
          Lwt.return v

    let resolve t reference =
      graph t
      >>= function
      | Error _ as err -> Lwt.return err
      | Ok graph -> (
        try Lwt.return (Ok (Graph.find reference graph)) with Not_found ->
          Lwt.return (Error `Not_found) )

    let write t reference value =
      with_buffer t (fun {raw; _} ->
          Reference.write ~fs:t.fs ~root:t.dotgit ~raw reference value )
      >>= function
      | Error (#Reference.error as err) -> Lwt.return (Error (err : error))
      | Ok () -> (
        match Hashtbl.mem t.packed reference with
        | false -> Lwt.return (Ok ())
        | true -> (
            with_buffer t (fun {dtmp; raw; _} ->
                Packed_refs.read ~fs:t.fs ~root:t.dotgit ~dtmp ~raw )
            >>= function
            | Error e -> Lwt.return (Error (e :> error))
            | Ok packed_refs -> (
                Lwt_list.fold_left_s
                  (fun acc -> function
                    | `Peeled _ as v -> Lwt.return (v :: acc)
                    | `Ref (refname, hash)
                      when not Reference.(equal (of_string refname) reference)
                      ->
                        Lwt.return (`Ref (refname, hash) :: acc)
                    | _ -> Lwt.return acc )
                  [] packed_refs
                >>= fun packed_refs' ->
                Hashtbl.reset t.packed ;
                List.iter
                  (function
                    | `Ref (refname, hash) ->
                        Hashtbl.add t.packed (Reference.of_string refname) hash
                    | `Peeled _ -> ())
                  packed_refs' ;
                let temp_dir = Fpath.(t.dotgit / "tmp") in
                with_buffer t (fun {raw; _} ->
                    Packed_refs.write ~fs:t.fs ~root:t.dotgit ~temp_dir ~raw
                      packed_refs' )
                >|= function Ok () -> Ok () | Error e -> Error (e :> error) ) )
        )
  end

  let cache ?(indexes = 5) ?(packs = 5) ?(objects = 5) ?(values = 5)
      ?(revindexes = 5) () =
    { indexes= CacheIndex.create indexes
    ; packs= CachePack.create packs
    ; objects= CacheObject.create objects
    ; values= CacheValue.create values
    ; revindexes= CacheRevIndex.create revindexes }

  let default_buffer () =
    let raw = Cstruct.create (0x8000 * 2) in
    let buf =
      Bigarray.Array1.create Bigarray.Char Bigarray.c_layout (2 * 0x8000)
    in
    { window= Inflate.window ()
    ; ztmp= Cstruct.sub raw 0 0x8000
    ; dtmp=
        Cstruct.of_bigarray ~off:0 ~len:0x8000 buf
        (* XXX(dinosaure): bon ici, c'est une note compliqué, j'ai mis 2 jours
           à fixer le bug. Donc je l'explique en français, c'est plus simple.

           En gros, [Helper.MakeDecoder] utilise ce buffer comme buffer interne
           pour gérer les alterations. Ce qui ce passe, c'est que dans la
           fonction [refill], il s'agit de compléter à partir d'un [input]
           (typiquement [zl]) le buffer interne. C'est finalement un
           __mauvais__ jeu entre un [Cstruct.t] et un [Bigarray].

           Il s'agit de connaître la véritable taille du [Bigarray] et de
           rajouter avec [blit] le contenu de l'[input] si la taille du
           [Bigarray] (et pas du [Cstruct]) est suffisante.

           Avant, cette modification, [zl], [de] et [io] partagaient le même
           [Bigarray] découpé (avec [Cstruct]) en 3. Donc, dans le
           [MakeDecoder], [refill] considérait (pour des gros fichiers faisant
           plus de 0x8000 bytes) que après [de], nous avions encore de la
           place - et dans ce cas, nous avions [io].

           Ainsi, on [blit]ait [zl] dans [de+sizeof(de) == io], et finalement,
           on se retrouvait à essayer de décompresser ce que nous avions
           décompressé. (YOLO).

           Donc, on considère maintenant [de] comme un [Cstruct.t] et un
           [Bigarray] physiquement différent pour éviter ce problème.
           Cependant, il faudrait continuer à introspecter car j'ai
           l'intuition que pour un fichier plus gros que [2 * 0x8000], on
           devrait avoir un problème. Donc TODO. *)
    ; raw= Cstruct.sub raw 0x8000 0x8000 }

  let sanitize_head git =
    Ref.mem git Reference.head
    >>= function
    | true -> Lwt.return (Ok ())
    | false -> Ref.write git Reference.head Reference.(Ref master)

  let sanitize_filesystem fs root dotgit =
    FS.Dir.create fs root
    >>?= (fun _ -> FS.Dir.create fs dotgit)
    >>?= (fun _ -> FS.Dir.create fs Fpath.(dotgit / "objects"))
    >>?= (fun _ -> FS.Dir.create fs Fpath.(dotgit / "objects" / "pack"))
    >>?= (fun _ -> FS.Dir.create fs Fpath.(dotgit / "objects" / "info"))
    >>?= (fun _ -> FS.Dir.create fs Fpath.(dotgit / "refs"))
    >>?= (fun _ -> FS.Dir.create fs Fpath.(dotgit / "tmp"))
    >>?= (fun _ -> Lwt.return (Ok ()))
    >>!= Error.FS.err_sys_dir

  let v ?dotgit ?(compression = 4) ?buffer fs root =
    let buffer =
      match buffer with
      | Some f -> f
      | None ->
          let p =
            Lwt_pool.create 4 (fun () -> Lwt.return (default_buffer ()))
          in
          Lwt_pool.use p
    in
    let dotgit =
      match dotgit with Some d -> d | None -> Fpath.(root / ".git")
    in
    sanitize_filesystem fs root dotgit
    >>?= fun () ->
    indexes ~fs dotgit
    >>?= fun engine ->
    let git =
      { fs
      ; dotgit
      ; root
      ; compression
      ; allocation= Pack.default 4
      ; engine
      ; packed= Hashtbl.create 64
      ; cache= cache ()
      ; buffer }
    in
    sanitize_head git >>?= fun () -> Lwt.return (Ok git)

  let clear_caches t =
    CacheIndex.drop_lru t.cache.indexes ;
    CacheRevIndex.drop_lru t.cache.revindexes ;
    CachePack.drop_lru t.cache.packs ;
    CacheValue.drop_lru t.cache.values ;
    CacheObject.drop_lru t.cache.objects ;
    Lwt.return ()

  let reset t =
    Log.info (fun l -> l ~header:"reset" "Start to reset the Git repository") ;
    FS.Dir.delete t.fs Fpath.(t.dotgit / "objects")
    >>?= (fun () ->
           FS.Dir.create t.fs Fpath.(t.dotgit / "objects")
           >>?= fun _ ->
           FS.Dir.create t.fs Fpath.(t.dotgit / "objects" / "info")
           >>?= fun _ ->
           FS.Dir.create t.fs Fpath.(t.dotgit / "objects" / "pack")
           >>?= fun _ ->
           FS.Dir.delete t.fs Fpath.(t.dotgit / "refs")
           >>?= fun () ->
           FS.Dir.create t.fs Fpath.(t.dotgit / "refs" / "heads")
           >>?= fun _ -> FS.Dir.create t.fs Fpath.(t.dotgit / "refs" / "tags")
           )
    >>!= Error.FS.err_sys_dir
    >>?= fun _ -> Ref.write t Reference.head Reference.(Ref master)

  (* XXX(dinosaure): an empty git repository has HEAD which points to a
     non-existing refs/heads/master. *)

  let dotgit {dotgit; _} = dotgit
  let root {root; _} = root
  let compression {compression; _} = compression
end
