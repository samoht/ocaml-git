module type S =
sig
  module Digest     : Ihash.IDIGEST
  module Path       : Path.S
  module FileSystem : Fs.S
  module Hash       : Common.BASE

  type t = private string

  val head    : t
  val master  : t

  val is_head : t -> bool

  val of_string : string -> t
  val to_string : t -> string

  include Common.BASE with type t := t

  type head_contents =
    | Hash of Hash.t
    | Ref of t

  val pp_head_contents : Format.formatter -> head_contents -> unit

  module A : Common.ANGSTROM with type t = head_contents
  module D : Common.DECODER with type t = head_contents
                             and type raw = Cstruct.t
                             and type init = Cstruct.t
                             and type error = [ `Decoder of string ]

  type error =
    [ FileSystem.File.error
    | D.error ]

  val pp_error  : Format.formatter -> error -> unit

  val from_file : Path.t -> dtmp:Cstruct.t -> raw:Cstruct.t -> ((t * head_contents), error) result Lwt.t
end

module Make
    (Digest : Ihash.IDIGEST with type t = Bytes.t
                             and type buffer = Cstruct.t)
    (Path : Path.S)
    (FileSystem : Fs.S with type path = Path.t
                        and type File.error = [ `System of string ]
                        and type File.raw = Cstruct.t)
  : S with type Hash.t = Digest.t
       and module Digest = Digest
       and module Path = Path
       and module FileSystem = FileSystem
= struct
  module Digest = Digest
  module Path = Path
  module FileSystem = FileSystem
  module Hash = Helper.BaseBytes

  let hash_of_hex_string x =
    Helper.BaseBytes.of_hex (Bytes.unsafe_of_string x)

  type t = string

  let head    = "HEAD"
  let is_head = String.equal head
  let master  = "refs/heads/master"

  let of_string x = x
  let to_string x = x

  let pp fmt x =
    Format.fprintf fmt "%s" (String.escaped x)

  let equal   = String.equal
  let hash    = Hashtbl.hash

  let compare x y =
    match x, y with
    | "HEAD", "HEAD" -> 0
    | "HEAD", _      -> (-1)
    | _     , "HEAD" -> 1
    | _     , _      -> compare x y

  module Set = Set.Make(struct type nonrec t = t let compare = compare end)
  module Map = Map.Make(struct type nonrec t = t let compare = compare end)

  type head_contents =
    | Hash of Hash.t
    | Ref of t

  let pp_head_contents fmt = function
    | Hash hash -> Format.fprintf fmt "(Hash %a)" Hash.pp hash
    | Ref t -> Format.fprintf fmt "(Ref %a)" pp t

  module A =
  struct
    type nonrec t = head_contents

    open Angstrom

    let refname =
      take_while (function '\000' .. '\039' -> false
                         | '\127'           -> false
                         | ' ' | '~' | '^'
                         | ':' | '?' | '*'
                         | '['              -> false
                         | _                -> true)

    let hash = take (Digest.length * 2)
      >>| hash_of_hex_string

    let decoder =
      (string "ref: " *> refname <* end_of_line >>| fun refname -> Ref refname)
      <|> (hash <* end_of_line >>| fun hash -> Hash hash)
  end

  module D = Helper.MakeDecoder(A)

  type error =
    [ FileSystem.File.error
    | D.error ]

  let pp_error fmt = function
    | #FileSystem.File.error as err -> Format.fprintf fmt "%a" FileSystem.File.pp_error err
    | #D.error as err -> Format.fprintf fmt "%a" D.pp_error err

  let normalize path =
    let segs = Path.segs path in

    List.fold_left
      (fun (stop, acc) ->
         if stop then fun x -> (true, x :: acc)
         else function
           | "HEAD" as x -> (true, x :: acc)
           (* XXX(dinosaure): special case, HEAD can be stored in a refs
              sub-directory or can be in root of dotgit (so, without refs). *)
           | "refs" as x -> (true, [ x ])
           | _ -> (false, []))
      (false, []) segs
    |> fun (_, refs) -> List.rev refs |> String.concat "/"

  let from_file path ~dtmp ~raw =
    let decoder = D.default dtmp in

    let open Lwt.Infix in

    FileSystem.File.open_r ~mode:0o400 ~lock:(Lwt.return ()) path
    >>= function
    | Error (#FileSystem.File.error as err) -> Lwt.return (Error err)
    | Ok read ->
      let rec loop decoder = match D.eval decoder with
        | `Await decoder ->
          FileSystem.File.read raw read >>=
          (function
            | Error (#FileSystem.File.error as err) -> Lwt.return (Error err)
            | Ok n -> match D.refill (Cstruct.sub raw 0 n) decoder with
              | Ok decoder -> loop decoder
              | Error (#D.error as err) -> Lwt.return (Error err))
        | `End (rest, value) -> Lwt.return (Ok value)
        | `Error (res, (#D.error as err)) -> Lwt.return (Error err)
      in

      loop decoder
      >|= function
      | Ok head_contents ->
        Ok (normalize path, head_contents)
      | Error _ as e -> e
end
