(* This file is free software, part of nunchaku. See file "license" for more details. *)

module ID = ID
module Stmt = Statement
module Loc = Location

type id = ID.t
type loc = Loc.t
type 'a printer = Format.formatter -> 'a -> unit

type ('t, 'ty, 'inv) def =
  | Fun_def of
      ('t, 'ty, 'inv) Statement.rec_defs *
      ('t, 'ty, 'inv) Statement.rec_def *
      loc option
      (** ID is a defined fun/predicate. *)

  | Fun_spec of
      (('t, 'ty) Statement.spec_defs * loc option) list

  | Data of
      [`Codata | `Data] *
      'ty Statement.mutual_types *
      'ty Statement.tydef
      (** ID is a (co)data *)

  | Cstor of
      [`Codata | `Data] *
      'ty Statement.mutual_types *
      'ty Statement.tydef *
      'ty Statement.ty_constructor
      (** ID is a constructor (of the given type) *)

  | Pred of
      [`Wf | `Not_wf] *
      [`Pred | `Copred] *
      ('t, 'ty, 'inv) Statement.pred_def *
      ('t, 'ty, 'inv) Statement.pred_def list *
      loc option

  | NoDef
      (** Undefined symbol *)

(** All information on a given symbol *)
type ('t, 'ty, 'inv) info = {
  ty: 'ty; (** type of symbol *)
  decl_kind: Statement.decl;
  loc: loc option;
  def: ('t, 'ty, 'inv) def;
}

(** Maps ID to their type and definitions *)
type ('t, 'ty, 'inv) t = {
  infos: ('t, 'ty, 'inv) info ID.PerTbl.t;
}

exception InvalidDef of id * string

let pp_invalid_def_ out = function
  | InvalidDef (id, msg) ->
      Format.fprintf out "@[<2>invalid definition for `%a`:@ %s@]" ID.print id msg
  | _ -> assert false

let () = Printexc.register_printer
  (function
      | InvalidDef _ as e -> Some (CCFormat.to_string pp_invalid_def_ e)
      | _ -> None
  )

let errorf_ id msg =
  Utils.exn_ksprintf msg ~f:(fun msg -> raise (InvalidDef(id,msg)))

let loc t = t.loc
let def t = t.def
let ty t = t.ty
let decl_kind t = t.decl_kind

let create ?(size=64) () = {infos=ID.PerTbl.create size}

let check_not_defined_ t ~id ~fail_msg =
  if ID.PerTbl.mem t.infos id then errorf_ id fail_msg

let declare ?loc ~kind ~env:t id ty =
  check_not_defined_ t ~id ~fail_msg:"already declared";
  let info = {loc; decl_kind=kind; ty; def=NoDef} in
  {infos=ID.PerTbl.replace t.infos id info}

let rec_funs ?loc ~env:t defs =
  List.fold_left
    (fun t def ->
      let id = def.Stmt.rec_defined.Stmt.defined_head in
      if ID.PerTbl.mem t.infos id
        then errorf_ id "already declared or defined";
      let info = {
        loc;
        ty=def.Stmt.rec_defined.Stmt.defined_ty;
        decl_kind=def.Stmt.rec_kind;
        def=Fun_def (defs, def, loc);
      } in
      {infos=ID.PerTbl.replace t.infos id info}
    ) t defs

let declare_rec_funs ?loc ~env defs =
  List.fold_left
    (fun env def ->
      let d = def.Stmt.rec_defined in
      let id = d.Stmt.defined_head in
      declare ~kind:def.Stmt.rec_kind ?loc ~env id d.Stmt.defined_ty
    )
    env defs

let find_exn ~env:t id = ID.PerTbl.find t.infos id

let find ~env:t id =
  try Some (find_exn ~env:t id)
  with Not_found -> None

let spec_funs
: type inv.
  ?loc:loc ->
  env:('t, 'ty, inv) t ->
  ('t, 'ty) Statement.spec_defs ->
  ('t, 'ty, inv) t
= fun ?loc ~env:t spec ->
  List.fold_left
    (fun t defined ->
      let id = defined.Stmt.defined_head in
      try
        let info = ID.PerTbl.find t.infos id in
        let l = match info.def with
          | Data _
          | Cstor _
          | Fun_def _
          | Pred _ -> errorf_ id "already defined"
          | Fun_spec l -> l
          | NoDef -> [] (* first def of id *)
        in
        let def = Fun_spec ((spec, loc) :: l) in
        {infos=ID.PerTbl.replace t.infos id {info with def; }}
      with Not_found ->
        errorf_ id "function is defined but was never declared"
    )
    t spec.Stmt.spec_defined

let def_data ?loc ~env:t ~kind tys =
  List.fold_left
    (fun t tydef ->
      (* define type *)
      let id = tydef.Stmt.ty_id in
      check_not_defined_ t ~id ~fail_msg:"is (co)data, but already defined";
      let info = {
        loc;
        decl_kind=Stmt.Decl_type;
        ty=tydef.Stmt.ty_type;
        def=Data (kind, tys, tydef);
      } in
      let t = {infos=ID.PerTbl.replace t.infos id info} in
      (* define constructors *)
      ID.Map.fold
        (fun _ cstor t ->
          let id = cstor.Stmt.cstor_name in
          check_not_defined_ t ~id ~fail_msg:"is constructor, but already defined";
          let info = {
            loc;
            decl_kind=Stmt.Decl_fun;
            ty=cstor.Stmt.cstor_type;
            def=Cstor (kind,tys,tydef, cstor);
          } in
          {infos=ID.PerTbl.replace t.infos id info}
        ) tydef.Stmt.ty_cstors t
    ) t tys

let def_pred ?loc ~env ~wf ~kind def l =
  let id = def.Stmt.pred_defined.Stmt.defined_head in
  check_not_defined_ env ~id
    ~fail_msg:"is (co)inductive pred, but already defined";
  let info = {
    loc;
    decl_kind=Stmt.Decl_prop;
    ty=def.Stmt.pred_defined.Stmt.defined_ty;
    def=Pred(wf,kind,def,l,loc);
  } in
  {infos=ID.PerTbl.replace env.infos id info}


let def_preds ?loc ~env ~wf ~kind l =
  List.fold_left
    (fun env def ->
      def_pred ?loc ~env ~wf ~kind def l)
    env l

let add_statement
: type inv.
  env:('t,'ty,inv) t ->
  ('t,'ty,inv) Statement.t ->
  ('t,'ty,inv) t
= fun ~env st ->
  let loc = Stmt.loc st in
  match Stmt.view st with
  | Stmt.Decl (id,kind,ty) ->
      declare ?loc ~kind ~env id ty
  | Stmt.TyDef (kind,l) ->
      def_data ?loc ~env ~kind l
  | Stmt.Goal _ -> env
  | Stmt.Axiom (Stmt.Axiom_std _) -> env
  | Stmt.Axiom (Stmt.Axiom_spec l) ->
      spec_funs ?loc ~env l
  | Stmt.Axiom (Stmt.Axiom_rec l) ->
      rec_funs ?loc ~env l
  | Stmt.Pred (wf, kind, preds) ->
      def_preds ?loc ~env ~wf ~kind preds

let mem ~env ~id = ID.PerTbl.mem env.infos id

let find_ty_exn ~env id = (find_exn ~env id).ty

let find_ty ~env id = CCOpt.map (fun x -> x.ty) (find ~env id)
