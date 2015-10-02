
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Unification of Types} *)

module Var = NunVar
module Sym = NunSymbol
module TyI = NunType_intf

type var = Var.t
type 'a sequence = ('a -> unit) -> unit

module Make(Ty : NunType_intf.UNIFIABLE) = struct
  exception Fail of Ty.t * Ty.t * string

  let spf = CCFormat.sprintf

  let () = Printexc.register_printer
    (function
      | Fail (ty1, ty2, msg) ->
          Some (spf "failed to unify %a and %a: %s" Ty.print ty1 Ty.print ty2 msg)
      | _ -> None
    )

  (* does [var] occur in [ty]? *)
  let rec occur_check_ ~var ty =
    match Ty.view ty with
    | TyI.App (f, l) ->
        occur_check_ ~var f || List.exists (occur_check_ ~var) l
    | TyI.Kind
    | TyI.Type
    | TyI.Builtin _ -> false
    | TyI.Var v ->
        Var.equal var v
        ||
        (match Ty.deref ty with
          | None -> false
          | Some ty' -> occur_check_ ~var ty'
        )
    | TyI.Arrow (a,b) -> occur_check_ ~var a || occur_check_ ~var b
    | TyI.Forall (v,t) ->
        (* [var] could be shadowed *)
        not (Var.equal var v) && occur_check_ ~var t

  (* NOTE: after dependent types are added, will need to recurse into
      types too for unification and occur-check *)

  let deref_rec ty = match Ty.deref ty with
    | None -> ty
    | Some ty' -> ty'

  let fail ty1 ty2 msg = raise (Fail (ty1, ty2, msg))

  let failf ty1 ty2 fmt =
    let b = Buffer.create 32 in
    let out = Format.formatter_of_buffer b in
    Format.kfprintf
      (fun _ -> Format.pp_print_flush out ();
        raise (Fail (ty1, ty2, Buffer.contents b)))
      out fmt

  let rec flatten_app_ f l = match Ty.view f with
    | TyI.App (f1, l1) -> flatten_app_ f1 (l1 @ l)
    | _ -> f, l

  (* bound: set of bound variables, that cannot be unified *)
  let unify_exn ty1 ty2 =
    let bound = ref Var.Map.empty in
    let rec unify_ ty1 ty2 =
      let ty1 = deref_rec ty1 in
      let ty2 = deref_rec ty2 in
      match Ty.view ty1, Ty.view ty2 with
      | TyI.Kind, TyI.Kind
      | TyI.Type, TyI.Type -> ()  (* success *)
      | TyI.Builtin s1, TyI.Builtin s2 ->
          if TyI.Builtin.equal s1 s2 then ()
          else fail ty1 ty2 "incompatible symbols"
      | TyI.Var v1, TyI.Var v2 when Var.Map.mem v1 !bound ->
          if Var.equal v2 (Var.Map.find v1 !bound) then ()
          else failf ty1 ty2 "variable %a is bound" Var.print v1
      | TyI.Var v1, TyI.Var v2 when Var.Map.mem v2 !bound ->
          if Var.equal v1 (Var.Map.find v2 !bound) then ()
          else failf ty1 ty2 "variable %a is bound" Var.print v2
      | TyI.Var var, _ ->
          assert (Ty.deref ty1=None);
          if occur_check_ ~var:var ty2
            then
              failf ty1 ty2
                "cycle detected (variable %a occurs in type)" Var.print var
            else Ty.bind ~var:ty1 ty2
      | _, TyI.Var var ->
          assert (Ty.deref ty2=None);
          if occur_check_ ~var:var ty1
            then
              failf ty1 ty2
                "cycle detected (variable %a occurs in type)" Var.print var
            else Ty.bind ~var:ty2 ty1
      | TyI.App (f1,l1), TyI.App (f2,l2) ->
          let f1, l1 = flatten_app_ f1 l1 in
          let f2, l2 = flatten_app_ f2 l2 in
          if List.length l1<>List.length l2
            then
              failf ty1 ty2 "different number of arguments (%d and %d resp.)"
                (List.length l1) (List.length l2);
          unify_ f1 f2;
          List.iter2 unify_ l1 l2
      | TyI.Arrow (l1,r1), TyI.Arrow (l2,r2) ->
          unify_ l1 l2;
          unify_ r1 r2
      | TyI.Forall (v1,t1), TyI.Forall (v2,t2) ->
          assert (not (Var.Map.mem v1 !bound));
          assert (not (Var.Map.mem v2 !bound));
          bound := Var.Map.add v1 v2 !bound;
          unify_ t1 t2
      | TyI.Kind, _
      | TyI.Type, _
      | TyI.Builtin _,_
      | TyI.App (_,_),_
      | TyI.Arrow (_,_),_
      | TyI.Forall (_,_),_ -> fail ty1 ty2 "incompatible types"
    in
    unify_ ty1 ty2

  let rec eval ty = match Ty.view ty with
    | TyI.Kind
    | TyI.Type
    | TyI.Builtin _ -> ty
    | TyI.Var _ ->
        begin match Ty.deref ty with
        | None -> ty
        | Some ty' -> eval ty'
        end
    | TyI.App (f,l) -> Ty.build (TyI.App (eval f, List.map eval l))
    | TyI.Arrow (a,b) -> Ty.build (TyI.Arrow (eval a, eval b))
    | TyI.Forall (v,t) -> Ty.build (TyI.Forall (v, eval t))

  let free_vars ?(init=Var.Set.empty) ty =
    let rec aux ~bound acc ty =
      (* follow pointers *)
      let ty = deref_rec ty in
      match Ty.view ty with
      | TyI.Kind | TyI.Type | TyI.Builtin _ -> acc
      | TyI.Var v ->
          if Var.Set.mem v bound then acc else Var.Set.add v acc
      | TyI.App (f,l) ->
          let acc = aux ~bound acc f in
          List.fold_left (aux ~bound) acc l
      | TyI.Arrow (a,b) ->
          let acc = aux ~bound acc a in
          aux ~bound acc b
      | TyI.Forall (v,t) ->
          (* must not return [v] *)
          aux ~bound:(Var.Set.add v bound) acc t
    in
    aux ~bound:Var.Set.empty init ty
end


