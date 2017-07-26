module type S =
sig
  module Digest : Ihash.IDIGEST
  module Hash : Common.BASE

  type entry =
    { perm : perm
    ; name : string
    ; node : Hash.t }
  and perm =
    [ `Normal | `Everybody | `Exec | `Link | `Dir | `Commit ]
  and t = entry list

  module D : Common.DECODER  with type t = t
                              and type raw = Cstruct.t
                              and type init = Cstruct.t
                              and type error = [ `Decoder of string ]
  module A : Common.ANGSTROM with type t = t
  module F : Common.FARADAY  with type t = t
  module M : Common.MINIENC  with type t = t
  module E : Common.ENCODER  with type t = t
                              and type raw = Cstruct.t
                              and type init = int * t
                              and type error = [ `Never ]

  include Ihash.DIGEST with type t := t and type hash = Hash.t
  include Common.BASE with type t := t

  val hashes : t -> Hash.t list
end

module Make (Digest : Ihash.IDIGEST with type t = Bytes.t
                                    and type buffer = Cstruct.t)
  : S with type Hash.t = Digest.t
       and module Digest = Digest
= struct
  module Digest = Digest
  module Hash = Helper.BaseBytes

  type entry =
    { perm : perm
    ; name : string
    ; node : Hash.t }
  and perm =
    [ `Normal | `Everybody | `Exec | `Link | `Dir | `Commit ]
  and t = entry list
  and hash = Hash.t

  let hashes tree = List.map (fun { node; _ } -> node) tree

  let pp_entry fmt { perm
                   ; name
                   ; node } =
    Format.fprintf fmt "{ @[<hov>perm = %s;@ \
                                 name = %s;@ \
                                 node = %a;@] }"
      (match perm with
       | `Normal -> "normal"
       | `Everybody -> "everybody"
       | `Exec -> "exec"
       | `Link -> "link"
       | `Dir -> "dir"
       | `Commit -> "commit")
      name Hash.pp node

  let list_pp ?(sep = (fun fmt () -> ())) pp_data fmt lst =
    let rec aux = function
      | [] -> ()
      | [ x ] -> pp_data fmt x
      | x :: r -> Format.fprintf fmt "%a%a" pp_data x sep (); aux r
    in
    aux lst

  let pp fmt tree =
    Format.fprintf fmt "[ @[<hov>%a@] ]"
      (list_pp ~sep:(fun fmt () -> Format.fprintf fmt "; ") pp_entry) tree

  let string_of_perm = function
    | `Normal    -> "100644"
    | `Everybody -> "100664"
    | `Exec      -> "100755"
    | `Link      -> "120000"
    | `Dir       -> "40000"
    | `Commit    -> "160000"

  let perm_of_string = function
    | "44"
    | "100644" -> `Normal
    | "100664" -> `Everybody
    | "100755" -> `Exec
    | "120000" -> `Link
    | "40000"  -> `Dir
    | "160000" -> `Commit
    | s -> raise (Invalid_argument "perm_of_string")

  module A =
  struct
    type nonrec t = t

    let is_not_sp chr = chr <> ' '
    let is_not_nl chr = chr <> '\x00'

    let hash = Angstrom.take Digest.length

    let sp = Format.sprintf

    let entry =
      let open Angstrom in

      take_while is_not_sp >>= fun perm ->
        (try return (perm_of_string perm)
         with _ -> fail (sp "Invalid permission %s" perm))
        <* commit
      >>= fun perm -> take 1 *> take_while is_not_nl <* commit
      >>= fun name -> take 1 *> hash <* commit
      >>= fun hash ->
        return { perm
               ; name
               ; node = Bytes.unsafe_of_string hash }
      <* commit

    let decoder = Angstrom.many entry
  end

  module F =
  struct
    type nonrec t = t

    let length t =
      let string x = Int64.of_int (String.length x) in
      let ( + ) = Int64.add in

      let entry acc x =
        (string (string_of_perm x.perm)) + 1L + (string x.name) + 1L + (Int64.of_int Digest.length) + acc
      in
      List.fold_left entry 0L t

    let sp = ' '
    let nl = '\x00'

    let entry e t =
      let open Farfadet in

      eval e [ !!string; char $ sp; !!string; char $ nl; !!string ]
        (string_of_perm t.perm)
        t.name
        (Bytes.unsafe_to_string t.node)

    let encoder e t =
      (Farfadet.list entry) e t
  end

  module M =
  struct
    open Minienc

    type nonrec t = t

    let sp = ' '
    let nl = '\x00'

    let entry x k e =
      (write_string (string_of_perm x.perm)
       @@ write_char sp
       @@ write_string x.name
       @@ write_char nl
       @@ write_string (Bytes.unsafe_to_string x.node) k)
        e

    let encoder x k e =
      let rec list l k e = match l with
        | x :: r ->
          (entry x
           @@ list r k)
            e
        | [] -> k e
      in

      list x k e
  end

  module D = Helper.MakeDecoder(A)
  module E = Helper.MakeEncoder(M)

  let digest value =
    let tmp = Cstruct.create 0x100 in
    Helper.fdigest (module Digest) (module E) ~tmp ~kind:"tree" ~length:F.length value

  let equal   = (=)
  let compare = Pervasives.compare
  let hash    = Hashtbl.hash

  module Set = Set.Make(struct type nonrec t = t let compare = compare end)
  module Map = Map.Make(struct type nonrec t = t let compare = compare end)
end

