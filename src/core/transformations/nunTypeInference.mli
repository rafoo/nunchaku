
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Scoping and Type Inference} *)

type 'a or_error = [`Ok of 'a | `Error of string]
type id = NunID.t
type 'a var = 'a NunVar.t
type 'a signature = 'a NunSignature.t
type loc = NunLocation.t

type stmt_invariant = [`Nested]

exception ScopingError of string * string * loc option
(** Scoping error for the given variable *)

(** {2 Type Inference/Checking}

  Functions exposed by this functor will mutate in place their input,
  by calling [Term.Ty.bind]. *)

type attempt_stack = NunUntypedAST.term list
(** a trace of inference attempts with a message and optional location
    for each attempt. *)

exception TypeError of string * attempt_stack
(** Raised when the input is ill-typed or could not be inferred. *)

module Convert(T : NunTerm_typed.S) : sig
  type env

  val empty_env : env
  (** Make a new, empty environment. The build function will be used
      to construct new T.ts *)

  val signature : env -> T.t signature

  val convert_ty : env:env -> NunUntypedAST.ty -> T.t or_error
  (** [convert ~env ty] converts the raw, unscoped type [ty] into a
      type from the representation [Ty.t].
      It returns an error if the type is ill-scoped. *)

  val convert_ty_exn : env:env -> NunUntypedAST.ty -> T.t
  (** @raise ScopingError if the type isnT.t well-scoped *)

  val convert_term : env:env -> NunUntypedAST.term -> T.t or_error
  (** [convert ~env ty] converts the raw, unscoped type [ty] into a
      type from the representation [Ty.t].
      It returns an error if the type is ill-scoped. *)

  val convert_term_exn : env:env -> NunUntypedAST.term -> T.t
  (** Unsafe version of {!convert}
      @raise TypeError if it fails to  type properly *)

  val generalize : close:[`Forall | `Fun | `NoClose] ->
                   T.t -> T.t * T.t var list
  (** Generalize a T.t [t] by parametrizing it over its free {b type}
      variables.
      @param close decides how [t] is generalized
        {ul
          {- [`Forall] makes [t' = forall vars t]}
          {- [`Fun] makes [t' = fun vars t]}
          {- [`NoClose] makes [t' = t] with meta variables replaced by [vars]}
        }
      @return a pair [(t', vars)] such that, roughly, [app t' vars = t],
        or [t'] is [forall vars t], or [t'] contains [vars] *)

  type statement = (T.t, T.t, stmt_invariant) NunStatement.t

  val convert_statement :
    env:env ->
    NunUntypedAST.statement ->
    (statement * env) or_error

  val convert_statement_exn :
    env:env ->
    NunUntypedAST.statement ->
    statement * env
  (** Unsafe version of {!convert} *)

  type problem = (T.t, T.t, stmt_invariant) NunProblem.t

  val convert_problem :
    env:env ->
    NunUntypedAST.statement list ->
    (problem * env) or_error

  val convert_problem_exn :
    env:env ->
    NunUntypedAST.statement list ->
    problem * env
end

module Make(T1 : NunTerm_typed.S)(T2 : NunTerm_ho.S) : sig
  type inv2 = <meta:[`NoMeta]; poly:[`Poly]>

  (** Decoding function used by {!pipe} *)
  val erase : inv2 T2.t NunModel.t -> NunUntypedAST.term NunModel.t

  (** Pipeline component. Takes input and output Term representations. *)
  val pipe :
    print:bool ->
    (NunUntypedAST.statement list,
      (T1.t, T1.t, stmt_invariant) NunProblem.t,
      inv2 T2.t NunModel.t, NunUntypedAST.term NunModel.t)
      NunTransform.t

  val pipe_with :
    decode:(signature:T1.t NunSignature.t -> 'c -> 'd) ->
    print:bool ->
    (NunUntypedAST.statement list,
      (T1.t, T1.t, stmt_invariant) NunProblem.t, 'c, 'd
    ) NunTransform.t
end
