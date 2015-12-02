
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Eliminate pattern-matching in Terms}

  Eliminate terms
  [match t with A x -> a | B -> b | C y z -> c]
  into
  [if is-A t then a[x := select-A-0 t]
   else if is-B t then b
   else c[y := select-C-0 t, z := select-C-1 t]
  ]

  which is a decision tree understandable by CVC4
*)

type id = ID.t

module Make(T : TermInner.S) : sig
  type term = T.t

  val elim_match : T.t -> T.t

  val tr_problem:
    (term, term, <ty:[`Mono]; eqn:'a>) Problem.t ->
    (term, term, <ty:[`Mono]; eqn:'a>) Problem.t

  val pipe :
    print:bool ->
      ((term, term, <ty:[`Mono]; eqn:'a>) Problem.t,
       (term, term, <ty:[`Mono]; eqn:'a>) Problem.t,
      'b, 'b
    ) Transform.t
  (** Pipeline component. Reverse direction is identity. *)
end