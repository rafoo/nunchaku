
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Unique Identifiers} *)

type t

include NunIntf.EQ with type t := t
include NunIntf.ORD with type t := t
include NunIntf.HASH with type t := t

val make : name:string -> t

val fresh_copy : t -> t
(** [fresh_copy v] makes a new identifier with the same name as [v] *)

val name : t -> string

val id : t -> int

include NunIntf.PRINT with type t := t
val to_string : t -> string

module Map : CCMap.S with type key = t
module Set : CCSet.S with type elt = t
