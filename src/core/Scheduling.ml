
(* This file is free software, part of nunchaku. See file "license" for more details. *)

(** {1 Scheduling of sub-processes} *)

type ('a, 'b) result =
  | Return of 'a
  | Return_shortcut of 'b  (** returns value, stop other processes *)
  | Fail of exn

type ('a, 'b) active_process = {
  thread: Thread.t;
  pid: int; (* pid of process *)
  stdin: out_channel;
  stdout: in_channel;
  mutable state : [`Running | `Stopped | `Done of ('a, 'b) result];
}

type ('a, 'b, 'c) pool = {
  j: int;
  mutable todo: 'a list;
  mutable active : ('b, 'c) active_process list;
  mutable pool_state : ('b list, 'c) result;
  lock: Mutex.t;
  cond: Condition.t;
}

(* create a new active process by running [cmd] and applying [f] on it *)
let start_task ~f pool cmd =
  Utils.debugf 3 "@[<2>start sub-process@ `@[%s@]`@]" (fun k->k cmd);
  let run ~stdout ~stdin ap =
    (* block until we get a result *)
    let res =
      try f cmd (stdout, stdin)
      with e -> Fail e
    in
    Utils.debugf 3 "@[<2>sub-process done:@ `@[%s@]`@]" (fun k->k cmd);
    (* update pool and active process *)
    Mutex.lock pool.lock;
    let ap = Lazy.force ap in
    ap.state <- `Done res;
    pool.active <-
      List.filter
        (fun ap' -> Thread.id ap.thread <> Thread.id ap'.thread)
        pool.active;
    begin match res, pool.pool_state with
      | Return x, Return l -> pool.pool_state <- Return (x::l)
      | Return_shortcut x, Return _ -> pool.pool_state <- Return_shortcut x;
      | Fail e, Return _ -> pool.pool_state <- Fail e
      | _, (Return_shortcut _ | Fail _) -> ()
    end;
    Condition.broadcast pool.cond; (* awake the main thread, if required *)
    Mutex.unlock pool.lock
  in
  (* spawn subprocess *)
  let stdout, p_stdout = Unix.pipe () in
  let p_stdin, stdin = Unix.pipe () in
  let stdout = Unix.in_channel_of_descr stdout in
  let stdin = Unix.out_channel_of_descr stdin in
  let pid = Unix.create_process
    "/bin/sh" [| "/bin/sh"; "-c"; cmd |] p_stdin p_stdout Unix.stderr in
  let rec ap = lazy {
    pid;
    stdin;
    stdout;
    thread = Thread.create (run ~stdout ~stdin) ap;
    state = `Running;
  } in
  Lazy.force ap

let kill_proc ap = match ap.state with
  | `Running ->
      Utils.ignore_catch Unix.close_process (ap.stdout, ap.stdin);
      Unix.kill ap.pid 9;
      (* Thread.kill ap.thread; (* not implemented? *) *)
      ap.state <- `Stopped
  | _ -> ()

(* main function for running threads *)
let rec run_pool ~f ~cmd pool =
  Mutex.lock pool.lock;
  match pool.todo, pool.active, pool.pool_state with
    | _, _, (Return_shortcut _ | Fail _) ->
        (* return now *)
        List.iter kill_proc pool.active;
        Mutex.unlock pool.lock;
        pool.pool_state
    | [], [], _ ->
        Mutex.unlock pool.lock;
        pool.pool_state
    | a :: todo', _, Return _ ->
        if List.length pool.active < pool.j
        then (
          (* run new task *)
          pool.todo <- todo';
          try
            let cmd' = cmd a in
            pool.active <- start_task ~f pool cmd' :: pool.active;
          with e ->
            pool.pool_state <- Fail e; (* fail *)
        ) else (
          (* wait for something to happen *)
          Condition.wait pool.cond pool.lock;
        );
        Mutex.unlock pool.lock;
        run_pool ~f ~cmd pool
    | [], _::_, Return _ ->
        (* wait for something to happen *)
        Condition.wait pool.cond pool.lock;
        Mutex.unlock pool.lock;
        (* check again *)
        run_pool ~f ~cmd pool

let run ~j ~cmd ~f args =
  if j < 1 then invalid_arg "Scheduling.run";
  let pool = {
    todo=args;
    active=[];
    pool_state = Return [];
    j;
    lock=Mutex.create();
    cond=Condition.create();
  } in
  run_pool ~f ~cmd pool
