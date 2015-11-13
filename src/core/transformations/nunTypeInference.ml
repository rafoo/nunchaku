
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Scoping and Type Inference} *)

module A = NunUntypedAST
module E = CCError
module ID = NunID
module Var = NunVar
module MetaVar = NunMetaVar
module Loc = NunLocation
module Sig = NunSignature

module TI = NunTermInner
module TyI = NunTypePoly

type 'a or_error = [`Ok of 'a | `Error of string]
type id = NunID.t
type 'a var = 'a Var.t
type 'a signature = 'a Sig.t
type loc = Loc.t

let fpf = Format.fprintf
let spf = CCFormat.sprintf
let section = NunUtils.Section.make "type_infer"

type attempt_stack = NunUntypedAST.term list

type stmt_invariant = <ty:[`Poly]; eqn:[`Nested]>

exception ScopingError of string * string * loc option
exception IllFormed of string * string * loc option (* what, msg, loc *)
exception TypeError of string * attempt_stack

(* print a stack *)
let print_stack out st =
  let print_frame out t =
    fpf out "@[<hv 2>trying to infer type of@ `@[%a@]`@ at %a@]"
      A.print_term t Loc.print_opt (Loc.get_loc t) in
  fpf out "@[<hv>%a@]"
    (CCFormat.list ~start:"" ~stop:"" ~sep:" " print_frame) st

let () = Printexc.register_printer
  (function
    | ScopingError (v, msg, loc) ->
        Some (spf "@[scoping error for var %s:@ %s@ at %a@]"
          v msg Loc.print_opt loc)
    | IllFormed(what, msg, loc) ->
        Some (spf "@[ill-formed %s:@ %s@ at %a@]"
          what msg Loc.print_opt loc)
    | TypeError (msg, stack) ->
        Some (spf "@[<2>type error:@ %s@ %a@]" msg print_stack stack)
    | _ -> None
  )

let scoping_error ?loc v msg = raise (ScopingError (v, msg, loc))

module MStr = Map.Make(String)

(* for the environment *)
type ('t, 'ty) term_def =
  | Decl of id * 'ty
  | TyVar of 'ty var
  | Var of 'ty var
  | Def of 't (* variable := this term *)

(** {2 Typed Term} *)
module Convert(Term : NunTermTyped.S) = struct
  module TyPoly = NunTypePoly.Make(Term)
  module U = NunTermTyped.Util(Term)
  module Unif = NunTypeUnify.Make(Term)

  type term = Term.t

  (* Helpers *)

  let push_ t stack = t::stack

  let type_error ~stack msg = raise (TypeError (msg, stack))
  let type_errorf ~stack fmt =
    NunUtils.exn_ksprintf fmt
      ~f:(fun msg -> TypeError(msg, stack))

  let ill_formed ?loc ?(kind="term") msg = raise (IllFormed (kind, msg, loc))
  let ill_formedf ?loc ?kind fmt =
    NunUtils.exn_ksprintf fmt
      ~f:(fun msg -> ill_formed ?loc ?kind msg)

  (* try to unify ty1 and ty2.
      @param stack the trace of inference attempts *)
  let unify_in_ctx_ ~stack ty1 ty2 =
    try
      Unif.unify_exn ty1 ty2
    with Unif.Fail _ as e ->
      type_error ~stack (Printexc.to_string e)

  (* polymorphic/parametrized type? *)
  let ty_is_poly_ t = match TyPoly.repr t with
    | TyI.Forall _ -> true
    | _ -> false

  module P = TI.Print(Term)

  (* Environment *)

  module Env = struct
    type t = {
      vars: (term, term) term_def MStr.t; (* local vars *)
      signature : term signature;
      cstors: (string, id * term) Hashtbl.t;  (* constructor ID + type *)
      mutable metas: (string, term MetaVar.t) Hashtbl.t option;
    }
    (* map names to proper identifiers, with their definition *)

    let empty = {
      vars=MStr.empty;
      signature = Sig.empty;
      cstors=Hashtbl.create 16;
      metas=None;
    }

    let add_decl ~env v ~id ty = {
      env with vars=MStr.add v (Decl (id, ty)) env.vars;
    }

    let add_sig ~env ~id ty =  {
      env with signature=Sig.declare ~sigma:env.signature id ty;
    }

    let add_var ~env v ~var =
      let decl =
        if U.ty_returns_Type (Var.ty var)
        then TyVar var else Var var
      in
      { env with vars=MStr.add v decl env.vars }

    let add_vars ~env v l =
      assert (List.length v = List.length l);
      List.fold_left2 (fun env v v' -> add_var ~env v ~var:v') env v l

    let add_def ~env v ~as_ = {
      env with vars=MStr.add v (Def as_) env.vars;
    }

    let mem_var ~env v = MStr.mem v env.vars

    let add_cstor ~env ~name c ty =
      if Hashtbl.mem env.cstors name
        then ill_formedf ~kind:"constructor"
          "a constructor named %s is already defined" name;
      Hashtbl.add env.cstors name (c,ty)

    let find_var ?loc ~env v =
      try MStr.find v env.vars
      with Not_found -> scoping_error ?loc v "not bound in environment"

    let find_cstor ?loc ~env c =
      try Hashtbl.find env.cstors c
      with Not_found -> scoping_error ?loc c "not a known constructor"

    (* find a meta-var by its name, create it if non existent *)
    let find_meta_var ~env v =
      let tbl = match env.metas with
        | None ->
            let tbl = Hashtbl.create 16 in
            env.metas <- Some tbl;
            tbl
        | Some tbl -> tbl
      in
      try Hashtbl.find tbl v
      with Not_found ->
        let var = MetaVar.make ~name:v in
        Hashtbl.add tbl v var;
        var

    (* reset table of meta-variables *)
    let reset_metas ~env = CCOpt.iter Hashtbl.clear env.metas
  end

  type env = Env.t
  let empty_env = Env.empty

  let signature env = env.Env.signature

  (* find the closest available location *)
  let rec get_loc_ ~stack t = match Loc.get_loc t, stack with
    | Some l, _ -> Some l
    | None, [] -> None
    | None, t' :: stack' -> get_loc_ ~stack:stack' t'

  let rec convert_ty_ ~stack ~env (ty:A.ty) =
    let loc = get_loc_ ~stack ty in
    let stack = push_ ty stack in
    match Loc.get ty with
      | A.Builtin `Prop -> U.ty_prop
      | A.Builtin `Type -> U.ty_type
      | A.Builtin s ->
          ill_formedf ?loc ~kind:"type" "%a is not a type" A.Builtin.print s
      | A.App (f, l) ->
          U.ty_app ?loc
            (convert_ty_ ~stack ~env f)
            (List.map (convert_ty_ ~stack ~env) l)
      | A.Wildcard ->
          U.ty_meta_var ?loc (MetaVar.make ~name:"_")
      | A.Var v ->
          begin match Env.find_var ?loc ~env v with
            | Decl (id, t) ->
                (* var: _ ... _ -> Type mandatory *)
                unify_in_ctx_ ~stack (U.ty_returns t) U.ty_type;
                U.ty_const ?loc id
            | Var v -> ill_formedf ~kind:"type" "term variable %a in type" Var.print v
            | TyVar v ->
                unify_in_ctx_ ~stack
                  (U.ty_returns (Var.ty v))
                  U.ty_type;
                U.ty_var ?loc v
            | Def t -> t  (* expand def *)
          end
      | A.AtVar _ ->
          ill_formed ~kind:"type" ?loc "@ syntax is not available for types"
      | A.MetaVar v -> U.ty_meta_var (Env.find_meta_var ~env v)
      | A.TyArrow (a,b) ->
          U.ty_arrow ?loc
            (convert_ty_ ~stack ~env a)
            (convert_ty_ ~stack ~env b)
      | A.TyForall (v,t) ->
          let var = Var.make ~ty:U.ty_type ~name:v in
          let env = Env.add_var ~env v ~var in
          U.ty_forall ?loc var (convert_ty_ ~stack ~env t)
      | A.Fun (_,_) -> ill_formed ?loc "no functions in types"
      | A.Let (_,_,_) -> ill_formed ?loc "no let in types"
      | A.Match _ -> ill_formed ?loc "no match in types"
      | A.Ite _ -> ill_formed ?loc "no if/then/else in types"
      | A.Forall (_,_)
      | A.Exists (_,_) -> ill_formed ?loc "no quantifiers in types"

  let convert_ty_exn ~env ty = convert_ty_ ~stack:[] ~env ty

  let convert_ty ~env ty =
    try E.return (convert_ty_exn ~env ty)
    with e -> E.of_exn e

  let prop = U.ty_prop
  let arrow_list ?loc = List.fold_right (U.ty_arrow ?loc)

  let fresh_ty_var_ ~name =
    let name = "ty_" ^ name in
    U.ty_meta_var (MetaVar.make ~name)

  (* number of "implicit" arguments (quantified) *)
  let rec num_implicit_ ty = match TyPoly.repr ty with
    | TyI.Forall (_,ty') -> 1 + num_implicit_ ty'
    | _ -> 0

  (* explore the type [ty], and add fresh type variables in the corresponding
     positions of [l] *)
  let rec fill_implicit_ ?loc ty l =
    match TyPoly.repr ty, l with
    | TyI.Forall (_,ty'), l ->
        (* implicit argument, insert a variable *)
        A.wildcard ?loc () :: fill_implicit_ ?loc ty' l
    | TyI.Builtin _, _
    | TyI.Meta _, _
    | TyI.Const _, _
    | TyI.Var _, _
    | TyI.App (_,_),_ -> l
    | TyI.Arrow _, [] -> [] (* need an explicit argument *)
    | TyI.Arrow (_,ty'), a :: l' ->
        (* explicit argument *)
        a :: fill_implicit_ ?loc ty' l'

  module Subst = struct
    include Var.Subst

    (* evaluate the type [ty] under the explicit substitution [subst] *)
    let rec eval ~subst ty =
      let loc = Term.loc ty in
      match TyPoly.repr ty with
      | TyI.Const _
      | TyI.Builtin _
      | TyI.Meta _ -> ty
      | TyI.Var v ->
          begin try
            let ty' = find_exn ~subst v in
            eval ~subst ty'
          with Not_found -> ty
          end
      | TyI.App (f,l) ->
          U.ty_app ?loc (eval ~subst f) (List.map (eval ~subst) l)
      | TyI.Arrow (a,b) ->
          U.ty_arrow ?loc (eval ~subst a) (eval ~subst b)
      | TyI.Forall (v,t) ->
          (* preserve freshness of variables *)
          let v' = Var.fresh_copy v in
          let subst = add ~subst v (U.ty_var v') in
          U.ty_forall ?loc v' (eval ~subst t)
  end

  let ty_apply t l =
    let apply_error t =
      type_errorf ~stack:[]
        "cannot apply type `@[%a@]` to anything" P.print t
    in
    let rec app_ ~subst t l = match TyPoly.repr t, l with
      | _, [] -> Subst.eval ~subst t
      | TyI.Builtin _, _
      | TyI.App (_,_),_
      | TyI.Const _, _ ->
          apply_error t
      | TyI.Var v, _ ->
          begin try
            let t = Subst.find_exn ~subst v in
            app_ ~subst t l
          with Not_found ->
            apply_error t
          end
      | TyI.Meta _,_ -> assert false
      | TyI.Arrow (a, t'), b :: l' ->
          unify_in_ctx_ ~stack:[] a b;
          app_ ~subst t' l'
      | TyI.Forall (v,t'), b :: l' ->
          let subst = Subst.add ~subst v b in
          app_ ~subst t' l'
    in
    app_ ~subst:Subst.empty t l

  let is_eq_ t = match Loc.get t with
    | A.Builtin `Eq -> true
    | _ -> false

  (* convert a parsed term into a typed/scoped term *)
  let rec convert_term_ ~stack ~env t =
    let loc = get_loc_ ~stack t in
    let stack = push_ t stack in
    match Loc.get t with
    | A.Builtin `Eq ->
        ill_formed ~kind:"term" ?loc "equality must be fully applied"
    | A.Builtin s ->
        (* only some symbols correspond to terms *)
        let prop1 = U.ty_arrow prop prop in
        let prop2 = arrow_list [prop; prop] prop in
        let b, ty = match s with
          | `Imply -> `Imply, prop2
          | `Or -> `Or, prop2
          | `And -> `And, prop2
          | `Prop -> ill_formed ?loc "`prop` is not a term, but a type"
          | `Type -> ill_formed ?loc "`type` is not a term"
          | `Not -> `Not, prop1
          | `True -> `True, prop
          | `False -> `False, prop
          | `Equiv -> `Equiv, prop2
          | `Eq -> assert false (* deal with earlier *)
        in
        U.builtin ?loc ~ty b
    | A.AtVar v ->
        begin match Env.find_var ?loc ~env v with
          | Decl (id, ty) ->
              U.const ?loc ~ty id
          | TyVar v -> U.ty_var ?loc v
          | Var var -> U.var ?loc var
          | Def t -> t
        end
    | A.MetaVar v -> U.ty_meta_var (Env.find_meta_var ~env v)
    | A.App (f, [a;b]) when is_eq_ f ->
        let a = convert_term_ ~stack ~env a in
        let b = convert_term_ ~stack ~env b in
        unify_in_ctx_ ~stack (U.ty_exn a) (U.ty_exn b);
        U.eq ?loc a b
    | A.App (f, l) ->
        (* infer type of [f] *)
        let f' = convert_term_ ~stack ~env f in
        let ty_f = U.ty_exn f' in
        (* complete with implicit arguments, if needed *)
        let l = match Loc.get f with
          | A.AtVar _ -> l (* all arguments explicit *)
          | _ ->
              fill_implicit_ ?loc ty_f l
        in
        (* now, convert elements of [l] depending on what is
           expected by the type of [f] *)
        let ty, l' = convert_arguments_following_ty
          ~stack ~env ~subst:Subst.empty ty_f l in
        U.app ?loc ~ty f' l'
    | A.Var v ->
        (* a variable might be applied, too *)
        let head, ty_head = match Env.find_var ?loc ~env v with
          | Decl (id, ty) ->
              U.const ?loc ~ty id, ty
          | Var var -> U.var ?loc var, Var.ty var
          | TyVar v -> U.ty_var ?loc v, Var.ty v
          | Def t -> t, U.ty_exn t
        in
        (* add potential implicit args *)
        let l = fill_implicit_ ?loc ty_head [] in
        (* convert [l] into proper types, of course *)
        let ty, l' = convert_arguments_following_ty
          ~stack ~env ~subst:Subst.empty ty_head l in
        U.app ?loc ~ty head l'
    | A.Forall ((v,ty_opt),t) ->
        convert_quantifier ?loc ~stack ~env ~which:`Forall v ty_opt t
    | A.Exists ((v,ty_opt),t) ->
        convert_quantifier ?loc ~stack ~env ~which:`Exists v ty_opt t
    | A.Fun ((v,ty_opt),t) ->
        (* fresh variable *)
        let ty_var = fresh_ty_var_ ~name:v in
        let var = Var.make ~ty:ty_var ~name:v in
        (* unify with expected type *)
        CCOpt.iter
          (fun ty ->
            unify_in_ctx_ ~stack ty_var (convert_ty_exn ~env ty)
          ) ty_opt;
        let env = Env.add_var ~env v ~var in
        let t = convert_term_ ~stack ~env t in
        (* NOTE: for dependent types, need to check whether [var] occurs in [type t]
           so that a forall is issued here instead of a mere arrow *)
        let ty = U.ty_arrow ?loc ty_var (U.ty_exn t) in
        U.fun_ ?loc var ~ty t
    | A.Let (v,t,u) ->
        let t = convert_term_ ~stack ~env t in
        let var = Var.make ~name:v ~ty:(U.ty_exn t) in
        let env = Env.add_var ~env v ~var in
        let u = convert_term_ ~stack ~env u in
        U.let_ ?loc var t u
    | A.Match (t,l) ->
        let t = convert_term_ ~stack ~env t in
        let ty_t = U.ty_exn t in
        (* build map (cstor -> case) for pattern match *)
        let m = List.fold_left
          (fun m (c,vars,rhs) ->
            (* find the constructor and the (co)inductive type *)
            let c, ty_c = Env.find_cstor ~env c in
            if ID.Map.mem c m
              then ill_formedf ?loc ~kind:"match"
                "constructor %a occurs twice in the list of cases"
                ID.print_name c;
            (* make scoped variables and infer their type from [t] *)
            let vars' = List.map
              (fun name -> Var.make ~name ~ty:(fresh_ty_var_ ~name)) vars in
            let ty' = ty_apply ty_c (List.map Var.ty vars') in
            unify_in_ctx_ ~stack:[] ty_t ty';
            (* now infer the type of [rhs] *)
            let env = Env.add_vars ~env vars vars' in
            let rhs = convert_term_ ~stack ~env rhs in
            ID.Map.add c (vars', rhs) m
          ) ID.Map.empty l
        in
        (* force all right-hand sides to have the same type *)
        let ty = try
          let (id,(_,rhs)) = ID.Map.choose m in
          let ty = U.ty_exn rhs in
          ID.Map.iter
            (fun id' (_,rhs') ->
              if not (ID.equal id id')
                then unify_in_ctx_ ~stack:[] ty (U.ty_exn rhs'))
            m;
          ty
        with Not_found ->
          ill_formedf ?loc ~kind:"match" "pattern-match needs at least one case"
        in
        (* TODO: also check exhaustiveness *)
        if not (TI.cases_well_formed m)
          then ill_formedf ?loc ~kind:"match"
            "ill-formed pattern match (non linear pattern or duplicated constructor)";
        U.match_with ~ty t m
    | A.Ite (a,b,c) ->
        let a = convert_term_ ~stack ~env a in
        let b = convert_term_ ~stack ~env b in
        let c = convert_term_ ~stack ~env c in
        (* a:prop, and b and c must have the same type *)
        unify_in_ctx_ ~stack (U.ty_exn a) prop;
        unify_in_ctx_ ~stack (U.ty_exn b) (U.ty_exn c);
        U.ite ?loc a b c
    | A.Wildcard ->
        (* TODO: generate fresh variable with new type?
            but then we need to quantify over it! *)
        type_error ~stack "term wildcards cannot be inferred"
    | A.TyForall _ -> type_error ~stack "terms cannot contain π"
    | A.TyArrow _ -> type_error ~stack "terms cannot contain arrows"

  (* convert elements of [l] into types or terms, depending on
     what [ty] expects. Return the converted list, along with
     what remains of [ty].
     @param subst the substitution of bound variables *)
  and convert_arguments_following_ty ~stack ~env ~subst ty l =
    match TyPoly.repr ty, l with
    | _, [] ->
        (* substitution is complete, evaluate [ty] now *)
        Subst.eval ~subst ty, []
    | TyI.Var _,_
    | TyI.App (_,_),_
    | TyI.Const _, _
    | TyI.Builtin _,_ ->
        type_errorf ~stack
          "@[term of type @[%a@] cannot accept argument,@ but was given @[<hv>%a@]@]"
          P.print ty (CCFormat.list A.print_term) l
    | TyI.Meta var, b :: l' ->
        (* must be an arrow type. We do not infer forall types *)
        assert (MetaVar.can_bind var);
        (* convert [b] and [l'] *)
        let b = convert_term_ ~stack ~env b in
        let ty_b = U.ty_exn b in
        (* type of the function *)
        let ty_ret = U.ty_meta_var (MetaVar.make ~name:"_") in
        MetaVar.bind ~var (U.ty_arrow ty_b ty_ret);
        (* application *)
        let ty', l' = convert_arguments_following_ty ~stack ~env ~subst ty_ret l' in
        ty', b :: l'
    | TyI.Arrow (a,ty'), b :: l' ->
        (* [b] must be a term whose type coincides with [subst a] *)
        let b = convert_term_ ~stack ~env b in
        let ty_b = U.ty_exn b in
        unify_in_ctx_ ~stack (Subst.eval ~subst a) ty_b;
        (* continue *)
        let ty', l' = convert_arguments_following_ty ~stack ~env ~subst ty' l' in
        ty', b :: l'
    | TyI.Forall (v,ty'), b :: l' ->
        (* [b] must be a type, and we replace [v] with [b] *)
        let b = convert_ty_exn ~env b in
        let subst = Subst.add ~subst v b in
        (* continue *)
        let ty', l' = convert_arguments_following_ty ~stack ~env ~subst ty' l' in
        ty', b :: l'

  and convert_quantifier ?loc ~stack ~env ~which v ty_opt t =
    (* fresh variable *)
    let ty_var = fresh_ty_var_ ~name:v in
    NunUtils.debugf ~section 3 "new variable %a for %s within %a"
      (fun k-> k P.print ty_var v A.print_term t);
    (* unify with expected type *)
    CCOpt.iter
      (fun ty ->
        unify_in_ctx_ ~stack ty_var (convert_ty_exn ~env ty)
      ) ty_opt;
    let var = Var.make ~name:v ~ty:ty_var in
    let env = Env.add_var ~env v ~var  in
    let t = convert_term_ ~stack ~env t in
    (* which quantifier to build? *)
    let builder = match which with
      | `Forall -> U.forall
      | `Exists -> U.exists
    in
    builder ?loc var t

  let convert_term_exn ~env t = convert_term_ ~stack:[] ~env t

  let convert_term ~env t =
    try E.return (convert_term_exn ~env t)
    with e -> E.of_exn e

  module Stmt = NunStatement

  type statement = (term, term, stmt_invariant) Stmt.t

  (* checks that the name is not declared/defined already *)
  let check_new_ ?loc ~env name =
    if Env.mem_var ~env name
      then ill_formedf ~kind:"statement" ?loc
        "identifier %s already defined" name

  exception InvalidTerm of term * string
  (* term (or its type) is not valid, for given reason *)

  let () = Printexc.register_printer
    (function
      | InvalidTerm (t, msg) ->
          Some (spf "@[<2>invalid term `@[%a@]`:@ %s@]" P.print t msg)
      | _ -> None)

  let invalid_term_ t msg = raise (InvalidTerm (t,msg))

  (* check that [t] is a monomorphic type or a term in which types
    are prenex, without metas ; convert it into a [term2] *)
  let rec is_mono_ t =
    match Term.repr t with
    | TI.TyMeta _ -> invalid_term_ t "remaining meta-variable"
    | TI.TyBuiltin _
    | TI.Const _ ->  true
    | TI.Var v -> is_mono_var_ v
    | TI.App (f,l) -> is_mono_ f && List.for_all is_mono_ l
    | TI.AppBuiltin (_,l) -> List.for_all is_mono_ l
    | TI.Let (v,t,u) ->
        is_mono_var_ v && is_mono_ t && is_mono_ u
    | TI.Match (t,l) ->
        is_mono_ t &&
        ID.Map.for_all
          (fun _ (vars,rhs) -> List.for_all is_mono_var_ vars && is_mono_ rhs)
          l
    | TI.Bind (`TyForall, _, _) -> false
    | TI.Bind (_,v,t) -> is_mono_var_ v && is_mono_ t
    | TI.TyArrow (a,b) -> is_mono_ a && is_mono_ b
  and is_mono_var_ v = is_mono_ (Var.ty v)

  (* check that [t] is a prenex type or a term in which types are monomorphic,
    and convert it to a [term2] *)
  and is_prenex_ t =
    match Term.repr t with
    | TI.TyBuiltin _
    | TI.Const _ -> true
    | TI.Var v -> is_mono_var_ v
    | TI.App (f,l) -> is_prenex_ f && List.for_all is_mono_ l
    | TI.AppBuiltin (_,l) -> List.for_all is_mono_ l
    | TI.Bind (`TyForall, v, t) ->
        (* pi v:_. t is prenex if t is *)
        is_mono_var_ v && is_prenex_ t
    | TI.Bind (`Forall, v, t) when U.ty_returns_Type (Var.ty v) ->
        (* forall v:type. t is prenex if t is *)
        is_prenex_ t
    | TI.Bind (_,v,t) -> is_mono_var_ v && is_mono_ t
    | TI.Let _
    | TI.Match _
    | TI.TyArrow _ -> is_mono_ t
    | TI.TyMeta _ -> false

  let check_ty_is_prenex_ ?loc t =
    if not (is_prenex_ t)
    then ill_formedf ?loc "type `@[%a@]` is not prenex" P.print t

  (* does [t] contain only prenex types? If not, convert it into [term2] *)
  let check_prenex_types_ ?loc t =
    if not (is_prenex_ t)
    then ill_formedf ?loc
        "@[<2>term `@[%a@]` contains non-prenex types@]" P.print t

  let check_ty_is_mono_ ?loc t =
    if not (is_mono_ t)
    then ill_formedf ?loc
        "@[<2>type `@[%a@]` is not monomorphic@]" P.print t

  let check_mono_var_ v =
    if not (is_mono_var_ v)
    then ill_formedf "@[variable %a has a non-monomorphic type" Var.print v

  let generalize ~close t =
    NunUtils.debugf ~section 5 "@[<2>generalize `@[%a@]`, by %s@]"
      (fun k->k P.print t
      (match close with `Fun -> "fun" | `Forall -> "forall" | `NoClose -> "no_close"));
    (* type meta-variables *)
    let vars = U.free_meta_vars t |> ID.Map.to_list in
    let t, new_vars = List.fold_right
      (fun (_,var) (t,new_vars) ->
        (* transform the meta-variable into a regular (type) variable *)
        let var' = Var.make ~name:(MetaVar.id var |> ID.name) ~ty:U.ty_type in
        MetaVar.bind ~var (U.ty_var var');
        (* build a function over [var'] *)
        let t = match close with
          | `Fun ->
              (* fun v1, ... , vn => t
                of type
                forall v1, ..., vn => typeof t *)
              let ty_t = U.ty_exn t in
              U.fun_ ~ty:(U.ty_forall var' ty_t) var' t
          | `Forall -> U.forall var' t
          | `NoClose -> t
        in
        t, var' :: new_vars
      ) vars (t, [])
    in
    if new_vars <> [] then
      NunUtils.debugf ~section 3 "@[generalized `%a`@ w.r.t @[%a@]@]"
        (fun k-> k P.print t (CCFormat.list Var.print) new_vars);
    t, new_vars

  (* convert [t] into a prop, call [f], generalize [t] *)
  let convert_prop_ ?(before_generalize=CCFun.const ()) ~env t =
    let t = convert_term_exn ~env t in
    unify_in_ctx_ ~stack:[] (U.ty_exn t) prop;
    before_generalize t;
    let t, _ = generalize ~close:`Forall t in
    check_prenex_types_ t;
    t

  (* checks that [t] only contains free variables from [vars].
    behavior depends on [rel]:
      {ul
        {- rel = `Equal means the set of free variables must be equal to [vars]}
        {- rel = `Subset means the set of free variables must be subset}
      }
  *)
  let check_vars ~vars ~rel t =
    let module VarSet = Var.Set(struct type t = term end) in
    let vars = VarSet.of_list vars in
    let fvars = U.to_seq_free_vars t
      |> Sequence.filter
        (fun v -> U.ty_returns_Type (Var.ty v))
      |> VarSet.of_seq
    in
    match rel with
      | `Equal ->
          if VarSet.equal fvars vars then `Ok
          else
            let symdiff = VarSet.(union (diff fvars vars) (diff vars fvars) |> to_list) in
            `Bad symdiff
      | `Subset ->
          if VarSet.subset fvars vars then `Ok
          else `Bad VarSet.(diff fvars vars |> to_list)

  (* convert [t as v] into a [Stmt.defined].
     [t] will be applied to fresh type variables if it lacks some type arguments.
     @return [(defined, vars, t')] where [vars] are the type variables of [t]
       that have been generalized, and [t'] is the generalized version of [t].
     @param pre_check called before generalization of [t] *)
  let convert_defined ?loc ?(pre_check=CCFun.const()) ~env t =
    let t = convert_term_exn ~env t in
    (* ensure [t] is applied to all required type arguments *)
    let num_missing_args = num_implicit_ (U.ty_exn t) in
    let l = CCList.init num_missing_args (fun _ -> fresh_ty_var_ ~name:"_") in
    let t = U.app ~ty:(ty_apply (U.ty_exn t) l) t l in
    pre_check t;
    (* replace meta-variables in [t] by real variables, and return those *)
    let t, vars = generalize ~close:`NoClose t in
    check_prenex_types_ ?loc t;
    (* head symbol and type arguments *)
    let defined_head, defined_ty_args =
      let id_ t =
        try U.head_sym t
        with Not_found ->
          ill_formedf ?loc ~kind:"defined_term" "does not have a head symbol"
      in
      match Term.repr t with
      | TI.Const id -> id, []
      | TI.App (f, l) ->
          let f = id_ f in
          let ty_f = Sig.find_exn ~sigma:env.Env.signature f in
          let n = num_implicit_ ty_f in
          assert (List.length l >= n);  (* we called [fill_implicit_] above *)
          f, CCList.take n l
      | _ ->
          ill_formedf ?loc ~kind:"defined_term"
            "`@[%a@]` is not a function application" P.print t
    in
    NunUtils.debugf ~section 4
      "@[<hv2>defined term `@[%a@]`@ has type `@[%a@]`@ and type tuple @[%a@]@]"
        (fun k -> k P.print t P.print (U.ty_exn t)
          (CCFormat.list P.print) defined_ty_args);
    List.iter (check_ty_is_mono_ ?loc) defined_ty_args;
    let defined = {Stmt.
      defined_head; defined_term=t; defined_ty_args;
    } in
    defined, vars, t

  (* convert a specification *)
  let convert_spec_defs ?loc ~env (untyped_defined_l, ax_l) =
    (* what are we specifying? a list of [Stmt.defined] terms *)
    let defined, env', vars = match untyped_defined_l with
      | [] -> assert false (* parser error *)
      | (t,v) :: tail ->
          let defined, vars, defined1 = convert_defined ?loc ~env t in
          (* locally, ensure that [v] refers to the defined term *)
          let env' = Env.add_def ~env v ~as_:defined1 in
          let env', l = NunUtils.fold_map
            (fun env' (t',v') ->
              let pre_check t' =
              (* check that [free_vars t = vars] *)
                match check_vars ~vars ~rel:`Equal t' with
                | `Ok -> ()
                | `Bad vars ->
                    ill_formedf ?loc ~kind:"spec"
                      "@[<2>the set of free type variables in two terms `@[%a@]` \
                      and `@[%a@]` of the same \
                      specification are not equal:@ @[%a@] occur in only \
                      one of them@]"
                      P.print defined.Stmt.defined_term
                      P.print t' (CCFormat.list Var.print) vars
              in
              let defined', _, defined1' = convert_defined ?loc ~pre_check ~env t' in
              let env' = Env.add_def ~env:env' v' ~as_:defined1' in
              env', defined'
            )
            env' tail
          in
          defined::l, env', vars
    in
    (* convert axioms. Use [env'] so that defined terms are represented
      by their aliases; then, dereference aliases to make them disappear *)
    let axioms = List.map
      (fun ax ->
        (* check that all the free type variables in [ax] occur in
            the defined term(s) *)
        let before_generalize t =
          match check_vars ~vars ~rel:`Subset t with
          | `Ok -> ()
          | `Bad bad_vars ->
              ill_formedf ?loc ~kind:"spec"
                "@[<2>axiom contains type variables @[`%a`@]@ \
                  that do not occur in defined term@ @[`%a`@]@]"
                (CCFormat.list Var.print) bad_vars P.print t
        in
        convert_prop_ ~before_generalize ~env:env' ax
      ) ax_l
    in
    (* check that no meta remains *)
    List.iter check_mono_var_ vars;
    {Stmt. spec_axioms=axioms; spec_vars=vars; spec_defined=defined; }

  (* extract [forall vars. f args = rhs] from a prop *)
  let rec extract_eqn ~f t = match Term.repr t with
    | TI.Bind (`Forall, v, t') ->
        CCOpt.map
          (fun (vars,args,rhs) -> v::vars,args,rhs)
          (extract_eqn ~f t')
    | TI.AppBuiltin (`Eq, [l;r]) ->
        begin match Term.repr l with
        | TI.App (f', args) ->
            begin match Term.repr f' with
            | TI.Const f' when ID.equal f f' -> Some ([], args, r)
            | _ -> None
            end
        | _ -> None
        end
    | _ -> None

  let convert_rec_defs ?loc ~env l =
    let allowed_vars = ref [] in (* type variables that can occur in axioms *)
    (* first, build new variables for the defined terms, and build [env']
        in which the variables are in scope *)
    let env', l' = NunUtils.fold_map
      (fun env' (untyped_t,v,l) ->
        let defined, vars, defined1 = convert_defined ?loc ~env untyped_t in
        allowed_vars := vars @ !allowed_vars;
        (* declare [v] in the scope of equations *)
        NunUtils.debugf ~section 4 "@[<2>locally define %s as `@[%a@]`@]"
          (fun k -> k v P.print defined1);
        let env' = Env.add_def ~env:env' v ~as_:defined1 in
        env', (defined,vars,l)
      ) env l
    in
    (* convert the equations *)
    List.map
      (fun (defined,vars,l) ->
        let rec_eqns = List.map
          (fun ax ->
            (* sanity check: equation must not contain other type variables *)
            let before_generalize t =
              match check_vars ~vars:!allowed_vars ~rel:`Subset t with
              | `Ok -> ()
              | `Bad vars ->
                  ill_formedf ?loc ~kind:"rec def"
                    "@[<2>equation `@[%a@]`,@ in definition of `@[%a@]`,@ \
                      contains type variables `@[%a@]` that do not occur \
                    in defined term@]"
                    A.print_term ax P.print defined.Stmt.defined_term
                    (CCFormat.list Var.print) vars
            in
            let ax = convert_prop_ ~before_generalize ~env:env' ax in
            (* decompose into a proper equation *)
            let f = defined.Stmt.defined_head in
            match extract_eqn ~f ax with
            | None ->
                ill_formedf ?loc
                  "@[<2>expected `@[forall <vars>.@ @[%a@] @[<hv><args>@ =@ <rhs>@]@]`@]"
                    ID.print_name f
            | Some (vars,args,rhs) ->
                (* remove type arguments (already present in defined) *)
                let num_ty_args = List.length defined.Stmt.defined_ty_args in
                let args = CCList.drop num_ty_args args in
                List.iter (check_prenex_types_ ?loc:None) args;
                Stmt.Eqn_nested (vars, args, rhs, [])
          )
          l
        in
        List.iter check_mono_var_ vars;
        (* return case *)
        {Stmt.
          rec_defined=defined; rec_vars=vars; rec_eqns;
        }
      )
      l'

  let ty_forall_l_ = List.fold_right (fun v t -> U.ty_forall v t)

  (* convert mutual (co)inductive types definition *)
  let convert_tydef ?loc ~env l =
    (* first, declare all the types *)
    let env, l = NunUtils.fold_map
      (fun env (name,vars,cstors) ->
        (* ensure this defines a type -> type -> ... -> type
          with as many arguments as [List.length vars] *)
        let ty = List.fold_right
          (fun _v t -> U.ty_arrow U.ty_type t)
          vars U.ty_type
        in
        let id = ID.make_full ~needs_at:false ~name in
        NunUtils.debugf ~section 3 "@[(co)inductive type %a: %a@]"
          (fun k-> k ID.print_name id P.print ty);
        (* declare *)
        let env' = Env.add_decl ~env name ~id ty in
        env', (id,vars,ty,cstors)
      ) env l
    in
    (* then declare constructors. *)
    NunUtils.fold_map
      (fun env (id,vars,ty_id,cstors) ->
        (* Type variables are declared in each constructor's scope,
            but not in the scope of other types in the
            same recursive definition *)
        let env', vars' = NunUtils.fold_map
          (fun env v ->
            let var = Var.make ~name:v ~ty:U.ty_type in
            Env.add_var ~env v ~var, var
          ) env vars
        in
        let ty_being_declared =
          U.app ~ty:U.ty_type
            (U.const ~ty:ty_id id)
            (List.map (fun v->U.ty_var v) vars')
        in
        (* for each constructor, find its type and declare it *)
        let env, cstors = NunUtils.fold_map
          (fun env (name,ty_args) ->
            let ty_args = List.map (convert_ty_exn ~env:env') ty_args in
            let ty' = ty_forall_l_ vars' (arrow_list ty_args ty_being_declared) in
            let id' = ID.make_full ~needs_at:(vars<>[]) ~name in
            let env = Env.add_decl ~env name ~id:id' ty' in
            NunUtils.debugf ~section 3 "@[constructor %a: %a@]"
              (fun k-> k ID.print_name id' P.print ty');
            Env.add_cstor ~env ~name id' ty';
            (* newly built constructor *)
            check_ty_is_prenex_ ?loc ty';
            List.iter (check_ty_is_mono_ ?loc) ty_args;
            let c = {Stmt.
              cstor_name=id'; cstor_type=ty'; cstor_args=ty_args;
            } in
            env, c
          ) env cstors
        in
        List.iter check_mono_var_ vars';
        check_ty_is_prenex_ ty_id;
        let tydef = {Stmt.
          ty_id=id; ty_vars=vars'; ty_type=ty_id; ty_cstors=cstors;
        } in
        env, tydef
      )
      env l

  module PStmt = Stmt.Print(P)(P)

  let convert_statement_exn ~env st =
    let name = st.A.stmt_name in
    let loc = st.A.stmt_loc in
    let info = {Stmt.name; loc; } in
    NunUtils.debugf ~section 2 "@[<hv2>infer types in@ %a@ at %a@]"
      (fun k-> k A.print_statement st Loc.print_opt loc);
    let st', env = match st.A.stmt_value with
    | A.Include _ ->
        ill_formed ?loc ~kind:"statement" "includes should have been eliminated"
    | A.Decl (v, ty) ->
        check_new_ ?loc ~env v;
        let ty = convert_ty_exn ~env ty in
        let id = ID.make_full ~needs_at:(ty_is_poly_ ty) ~name:v in
        let env = Env.add_decl ~env v ~id ty in
        check_ty_is_prenex_ ?loc ty;
        let env = Env.add_sig ~env ~id ty in
        if U.ty_returns_Type ty
          then Stmt.ty_decl ~info id ty, env (* id is a type *)
          else Stmt.decl ~info id ty, env
    | A.Axiom l ->
        (* convert terms, and force them to be propositions *)
        let l = List.map (convert_prop_ ?before_generalize:None ~env) l in
        Stmt.axiom ~info l, env (* default *)
    | A.Def (a,b) ->
        let a_defined = convert_term_exn ~env a in
        let ty = U.ty_exn a_defined in
        (* we are defining the head of [a], so declare it *)
        let id = U.head_sym a_defined in
        let env' = Env.add_def  ~env (ID.name id) ~as_:a_defined in
        let b = convert_term_exn ~env:env' b in
        check_prenex_types_ ?loc a_defined;
        check_prenex_types_ ?loc b;
        let eqn = Stmt.Eqn_nested ([], [], b, []) in
        unify_in_ctx_ ~stack:[] ty (U.ty_exn b);
        (* TODO: check that [v] does not occur in [b] *)
        let defined = {Stmt.
          defined_head=id; defined_term=a_defined; defined_ty_args=[];
        } in
        Stmt.axiom_rec ~info
          [{Stmt.rec_defined=defined; rec_vars=[]; rec_eqns=[eqn]; }]
        , env
    | A.Spec s ->
        let s = convert_spec_defs ?loc ~env s in
        Stmt.axiom_spec ~info s, env
    | A.Rec s ->
        let s = convert_rec_defs ?loc ~env s in
        Stmt.axiom_rec ~info s, env
    | A.Data l ->
        let env, l = convert_tydef ?loc ~env l in
        Stmt.data ~info l, env
    | A.Codata l ->
        let env, l = convert_tydef ?loc ~env l in
        Stmt.codata ~info l, env
    | A.Goal t ->
        (* infer type for t *)
        let t = convert_term_exn ~env t in
        (* be sure it's a proposition
           XXX: for narrowing, could be of any type? *)
        unify_in_ctx_ ~stack:[] (U.ty_exn t) prop;
        check_prenex_types_ ?loc t;
        Stmt.goal ~info t, env
    in
    NunUtils.debugf ~section 2 "@[<2>checked statement@ %a@]"
      (fun k-> k PStmt.print st');
    st', env

  let convert_statement ~env st =
    try E.return (convert_statement_exn ~env st)
    with e -> E.of_exn e

  type problem = (term, term, stmt_invariant) NunProblem.t

  let convert_problem_exn ~env l =
    let rec aux acc ~env l = match l with
      | [] -> List.rev acc, env
      | st :: l' ->
          let st, env = convert_statement_exn ~env st in
          Env.reset_metas ~env;
          aux (st :: acc) ~env l'
    in
    let l, env = aux [] ~env l in
    NunProblem.of_list ~meta:NunProblem.Metadata.default l, env

  let convert_problem ~env st =
    try E.return (convert_problem_exn ~env st)
    with e -> E.of_exn e
end

module Make(T1 : NunTermTyped.S)(T2 : NunTermInner.S) = struct
  type term1 = T1.t
  type term2 = T2.t

  module HO2 = NunTermPoly.Make(T2)

  let erase m =
    (* we get back "regular" HO terms *)
    let module Erase = NunTermPoly.Erase(HO2) in
    let ctx = Erase.create () in
    NunModel.map m ~f:(Erase.erase ~ctx)

  module THO = NunTerm_ho

  let pipe_with ~decode ~print =
    (* type inference *)
    let module Conv = Convert(T1) in
    let module P = TI.Print(T1) in
    let module PPb = NunProblem.Print(P)(P) in
    let on_encoded =
      if print
      then [Format.printf "@[<v2>after type inference: %a@]@." PPb.print]
      else []
    in
    NunTransform.make1
      ~on_encoded
      ~name:"type inference"
      ~encode:(fun l ->
        let problem, env = l
          |> Conv.convert_problem_exn ~env:Conv.empty_env
        in
        problem, Conv.signature env
      )
      ~decode:(fun signature x ->
        decode ~signature x
      )
      ()

  let pipe ~print =
    let decode ~signature:_ m = erase m in
    pipe_with ~decode ~print
end
