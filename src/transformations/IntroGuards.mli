
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Introduce Guards}

    This transformation removes "assuming" and "asserting" constructs and
    replaces them by boolean guards and assertions *)

open Nunchaku_core

module T = TermInner.Default

type term = T.t
type inv = <ty:[`Mono]; eqn:[`Absent]; ind_preds:[`Absent]>

val name : string

val encode_pb : (term, term, inv) Problem.t -> (term, term, inv) Problem.t

(** Pipeline component *)
val pipe :
  print:bool ->
  check:bool ->
  ((term, term, inv) Problem.t,
    (term, term, inv) Problem.t,
    'ret, 'ret) Transform.t