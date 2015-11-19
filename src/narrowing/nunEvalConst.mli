
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Constant} *)

type id = NunID.t

type 'term t = private {
  id: id; (* symbol *)
  ty: 'term; (* type of symbol *)
  mutable def: 'term def; (* definition/declaration for the symbol *)
}
and 'term def =
  | Cstor of
      'term (* the datatype *)
      * 'term t list (* list of all constructors *)

  | Def of 'term (* id == this term *)

  | Datatype of
      [`Data | `Codata]
      * 'term t list (* list of constructors *)

  | Opaque
  (* TODO: DefNode of term * node, for memoization *)

(* FIXME: how to compile multiple equations to Def? *)

val is_cstor : _ t -> bool
val is_def : _ t -> bool

val make : def:'term def -> ty:'term -> id -> 'term t
val set_ty : 'term t -> ty:'term -> 'term t

