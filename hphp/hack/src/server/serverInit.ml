(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Hh_core
open ServerEnv
open ServerCheckUtils
open Reordered_argument_collections
open Utils
open String_utils
open SearchServiceRunner

open Core_result.Export
open Core_result.Monad_infix

module DepSet = Typing_deps.DepSet
module Dep = Typing_deps.Dep
module SLC = ServerLocalConfig

exception Native_loader_failure of string
exception No_loader
exception Loader_timeout of string

type load_mini_approach =
  | Precomputed of ServerArgs.mini_state_target_info
  | Load_state_natively of bool
  | Load_state_natively_with_target of ServerMonitorUtils.target_mini_state

(** Docs are in .mli *)
type init_result =
  | Mini_load of int option
  | Mini_load_failed of string

let delete_async path =
  Sys_utils.rm_dir_tree path;
  exit 0

(* Utility functions for deleting a process, which have to be toplevel *)
let delete_and_log : (string) Process.Entry.t =
  Process.register_entry_point
    "Remove directory" delete_async

let rm_dir_tree_async path =
  Process.run_entry delete_and_log path

let load_mini_exn_to_string err = match err with
  | Future.Failure e ->
    Printf.sprintf "%s\n%s" (Future.error_to_string e) (Printexc.get_backtrace ())
  | e -> Printexc.to_string e

module ServerInitCommon = struct

  let lock_and_load_deptable fn ~ignore_hh_version =
    (* The sql deptable must be loaded in the master process *)
    try
      (* Take a lock on the info file for the sql *)
      LoadScriptUtils.lock_saved_state fn;
      let read_deptable_time =
        SharedMem.load_dep_table_sqlite fn ignore_hh_version
      in
      Hh_logger.log
        "Reading the dependency file took (sec): %d" read_deptable_time;
      HackEventLogger.load_deptable_end read_deptable_time;
    with
    | SharedMem.Sql_assertion_failure 11
    | SharedMem.Sql_assertion_failure 14 as e -> (* SQL_corrupt *)
      LoadScriptUtils.delete_corrupted_saved_state fn;
      raise e


  (* Return all the files that we need to typecheck *)
  let make_next_files genv : Relative_path.t MultiWorker.nextlist =
    let next_files_root = compose
      (List.map ~f:(Relative_path.(create Root)))
      (genv.indexer ServerEnv.file_filter) in
    let hhi_root = Hhi.get_hhi_root () in
    let hhi_filter = FindUtils.is_php in
    let next_files_hhi = compose
      (List.map ~f:(Relative_path.(create Hhi)))
      (Find.make_next_files
         ~name:"hhi" ~filter:hhi_filter hhi_root) in
    fun () ->
      let next = match next_files_hhi () with
      | [] -> next_files_root ()
      | x -> x
      in
      Bucket.of_list next

  let with_loader_timeout timeout stage f =
    Core_result.join @@ Core_result.try_with @@ fun () ->
    Timeout.with_timeout ~timeout ~do_:(fun _ -> f ())
      ~on_timeout:(fun _ -> raise @@ Loader_timeout stage)

  let invoke_loading_state_natively ~tiny ?(use_canary=false) ?target genv root =
    let mini_state_handle, tiny = begin match target with
    | None -> None, tiny
    | Some { ServerMonitorUtils.mini_state_everstore_handle; target_svn_rev; is_tiny; } ->
      let handle =
      Some
      {
        State_loader.mini_state_everstore_handle = mini_state_everstore_handle;
        mini_state_for_rev = (Hg.Svn_rev target_svn_rev);
      } in
      handle, is_tiny
    end in
    let native_load_error e = raise (Native_loader_failure (State_loader.error_string e)) in
    let ignore_hh_version = ServerArgs.ignore_hh_version genv.options in
    State_loader.mk_state_future ~config:genv.local_config.SLC.state_loader_timeouts
      ~use_canary ?mini_state_handle
      ~config_hash:(ServerConfig.config_hash genv.config) root ~tiny
      ~ignore_hh_version
      |> Core_result.map_error ~f:native_load_error
      >>= fun result ->
    lock_and_load_deptable result.State_loader.deptable_fn ~ignore_hh_version;
    let old_saved = open_in result.State_loader.saved_state_fn
      |> Marshal.from_channel in
    let get_dirty_files = (fun () ->
      let t = Unix.time () in
      result.State_loader.dirty_files
        (** Mercurial can respond with 90 thousand file changes in about 3 minutes. *)
        |> Future.get ~timeout:200
        |> Core_result.map_error ~f:Future.error_to_exn
        >>= fun dirty_files ->
      let () = HackEventLogger.state_loader_dirty_files t in
      let dirty_files = List.map dirty_files Relative_path.from_root in
      let dirty_files = Relative_path.set_of_list dirty_files in
      Ok (
        result.State_loader.saved_state_fn,
        result.State_loader.corresponding_rev,
        dirty_files,
        old_saved,
        Some result.State_loader.state_distance
      )
    ) in
    Ok get_dirty_files

  let invoke_approach genv root approach ~tiny =
    let ignore_hh_version = ServerArgs.ignore_hh_version genv.options in
    match approach with
    | Precomputed { ServerArgs.saved_state_fn;
      corresponding_base_revision; deptable_fn; changes } ->
      lock_and_load_deptable deptable_fn ~ignore_hh_version;
      let changes = Relative_path.set_of_list changes in
      let chan = open_in saved_state_fn in
      let old_saved = Marshal.from_channel chan in
      let get_dirty_files = (fun () -> Ok (
        saved_state_fn,
        (Hg.Svn_rev (int_of_string (corresponding_base_revision))),
        changes,
        old_saved,
        None
      )) in
      Core_result.try_with (fun () -> fun () -> Ok get_dirty_files)
    | Load_state_natively use_canary ->
      Ok (fun () ->
        try
          let result = invoke_loading_state_natively ~use_canary ~tiny genv root in
          begin match result, tiny with
          | Error _, true ->
            (* If we can't find a saved state but don't throw an exception,
              turn off tiny states and see if we have a regular one *)
            HackEventLogger.set_use_tiny_state false;
            invoke_loading_state_natively ~use_canary ~tiny:false genv root
          | _ -> result
          end
        with
        (** TODO: remove this after we migrate fully to tiny saved states.
        This happens when the sql file doesn't exist because it's under a
        different name, so Sql_assertion_failure 14 is thrown and we
        should delete the saved state. We only need to do this for now because
        we conflate tiny and non-tiny saved states and put them in the same
        directory and misuse one as the other kind when the directory is filled
         by some other process (or at an earlier time). *)
        (* If it fails, we delete the corrupted saved state and try again *)
        | SharedMem.Sql_assertion_failure 14 ->
          invoke_loading_state_natively ~use_canary ~tiny genv root)
    | Load_state_natively_with_target target ->
      Ok (fun () ->
        let is_tiny = target.ServerMonitorUtils.is_tiny in
        try
          HackEventLogger.set_use_tiny_state is_tiny;

          invoke_loading_state_natively ~tiny:is_tiny ~target genv root
        with
        | SharedMem.Sql_assertion_failure 14 ->
          (* TODO: Remove this after we migrate fully to tiny saved states. See above docs. *)
          (* If it fails, we delete the corrupted saved state and try again *)
          invoke_loading_state_natively ~tiny:is_tiny ~target genv root)

  let is_check_mode options =
    ServerArgs.check_mode options &&
    ServerArgs.convert options = None &&
    (* Note: we need to run update_files to get an accurate saved state *)
    ServerArgs.save_filename options = None

  let indexing genv =
    let logstring = "Indexing" in
    Hh_logger.log "Begin %s" logstring;
    let t = Unix.gettimeofday () in
    let get_next = make_next_files genv in
    HackEventLogger.indexing_end t;
    let t = Hh_logger.log_duration logstring t in
    get_next, t

  let parsing ~lazy_parse genv env ~get_next ?count t =
    let logstring =
      match count with
      | None -> "Parsing"
      | Some c -> Printf.sprintf "Parsing %d files" c in
    Hh_logger.log "Begin %s" logstring;
    let quick = lazy_parse in
    let files_info, errorl, _=
      Parsing_service.go
        ~quick
        genv.workers
        Relative_path.Set.empty
        ~get_next
        env.popt in
    let files_info = Relative_path.Map.union files_info env.files_info in
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    Stats.(stats.init_parsing_heap_size <- hs);
    (* TODO: log a count of the number of files parsed... 0 is a placeholder *)
    HackEventLogger.parsing_end t hs  ~parsed_count:0;
    let env = { env with
      files_info;
      errorl = Errors.merge errorl env.errorl;
    } in
    env, (Hh_logger.log_duration logstring t)

  let update_files genv files_info t =
    if is_check_mode genv.options then t else begin
      Typing_deps.update_files files_info;
      HackEventLogger.updating_deps_end t;
      Hh_logger.log_duration "Updating deps" t
    end

  let naming env t =
    let logstring = "Naming" in
    Hh_logger.log "Begin %s" logstring;
    let env =
      Relative_path.Map.fold env.files_info ~f:begin fun k v env ->
        let errorl, failed_naming = NamingGlobal.ndecl_file env.tcopt k v in
        { env with
          errorl = Errors.merge errorl env.errorl;
          failed_naming =
            Relative_path.Set.union env.failed_naming failed_naming;
        }
      end ~init:env
    in
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    HackEventLogger.global_naming_end t;
    env, (Hh_logger.log_duration logstring t)

  let type_decl genv env fast t =
    let logstring = "Type-decl" in
    Hh_logger.log "Begin %s" logstring;
    let bucket_size = genv.local_config.SLC.type_decl_bucket_size in
    let errorl =
      Decl_service.go ~bucket_size genv.workers env.tcopt fast in
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    Stats.(stats.init_heap_size <- hs);
    HackEventLogger.type_decl_end t;
    let t = Hh_logger.log_duration logstring t in
    let env = {
      env with
      errorl = Errors.merge errorl env.errorl;
    } in
    env, t

  (* Run naming from a fast generated from saved state.
   * No errors are generated because we assume the fast is directly from
   * a clean state.
   *)
  let naming_with_fast fast t =
    Relative_path.Map.iter fast ~f:begin fun k info ->
    let { FileInfo.n_classes=classes;
         n_types=typedefs;
         n_funs=funs;
         n_consts=consts} = info in
    NamingGlobal.ndecl_file_fast k ~funs ~classes ~typedefs ~consts
    end;
    HackEventLogger.fast_naming_end t;
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    (Hh_logger.log_duration "Naming fast" t)

  (*
   * In eager initialization, this is done at the parsing step with
   * parsing hooks. During lazy init, need to do it manually from the fast
   * instead since we aren't parsing the codebase.
   *)
  let update_search saved t =
    (* Only look at Hack files *)
    let fast = FileInfo.saved_to_hack_files saved in
    (* Filter out non php files *)
    let fast = Relative_path.Map.filter fast
      ~f:(fun s _ ->
          let fn = (Relative_path.to_absolute s) in
          not (FilesToIgnore.should_ignore fn)
          && FindUtils.is_php fn) in

    Relative_path.Map.iter fast
    ~f: (fun fn names ->
      SearchServiceRunner.update (fn, (SearchServiceRunner.Fast names));
    );
    HackEventLogger.update_search_end t;
    Hh_logger.log_duration "Loading search indices" t


  let type_check genv env fast t =
    if ServerArgs.ai_mode genv.options <> None then env, t
    else if is_check_mode genv.options ||
        (ServerArgs.save_filename genv.options <> None) then begin
      let count = Relative_path.Map.cardinal fast in
      let logstring = Printf.sprintf "Type-check %d files" count in
      Hh_logger.log "Begin %s" logstring;
      let errorl =
        Typing_check_service.go genv.workers env.tcopt fast in
      let hs = SharedMem.heap_size () in
      Hh_logger.log "Heap size: %d" hs;
      HackEventLogger.type_check_end count t;
      let env = { env with
        errorl = Errors.merge errorl env.errorl;
      } in
      env, (Hh_logger.log_duration logstring t)
    end else begin
      let needs_recheck = Relative_path.Map.fold fast
        ~init:Relative_path.Set.empty
        ~f:(fun fn _ acc -> Relative_path.Set.add acc fn)
      in
      let env = { env with
        needs_recheck = Relative_path.Set.union env.needs_recheck needs_recheck;
        needs_full_check = true;
        init_env = { env.init_env with
          needs_full_init = true;
        };
      } in
      env, t
    end

  let get_dirty_fast old_fast fast dirty =
    Relative_path.Set.fold dirty ~f:begin fun fn acc ->
      let dirty_fast = Relative_path.Map.get fast fn in
      let dirty_old_fast = Relative_path.Map.get old_fast fn in
      let fast = Option.merge dirty_old_fast dirty_fast FileInfo.merge_names in
      match fast with
      | Some fast -> Relative_path.Map.add acc ~key:fn ~data:fast
      | None -> acc
    end ~init:Relative_path.Map.empty

  let get_all_deps {FileInfo.n_funs; n_classes; n_types; n_consts} =
    let add_deps_of_sset dep_ctor sset depset =
      SSet.fold sset ~init:depset ~f:begin fun n acc ->
        let dep = dep_ctor n in
        let deps = Typing_deps.get_bazooka dep in
        DepSet.union deps acc
      end
    in
    let deps = add_deps_of_sset (fun n -> Dep.Fun n) n_funs DepSet.empty in
    let deps = add_deps_of_sset (fun n -> Dep.FunName n) n_funs deps in
    let deps = add_deps_of_sset (fun n -> Dep.Class n) n_classes deps in
    let deps = add_deps_of_sset (fun n -> Dep.Class n) n_types deps in
    let deps = add_deps_of_sset (fun n -> Dep.GConst n) n_consts deps in
    let deps = add_deps_of_sset (fun n -> Dep.GConstName n) n_consts deps in
    (* We need to type check all classes that have extend dependencies on the
     * classes that have changed
     *)
    let extend_deps =
        SSet.fold ~f:begin fun class_name acc ->
        let hash = Typing_deps.Dep.make (Dep.Class class_name) in
        Decl_compare.get_extend_deps hash acc
      end n_classes ~init:DepSet.empty in
    let deps = DepSet.union deps extend_deps in
    let deps = DepSet.fold extend_deps ~init:deps ~f:begin fun dep acc ->
    let deps = Typing_deps.get_ideps_from_hash dep in
      DepSet.union deps acc
    end in
    deps

  (* We start of with a list of files that have changed since the state was
   * saved (dirty_files), and two maps of the class / function declarations
   * -- one made when the state was saved (old_fast) and one made for the
   * current files in the repository (fast). We grab the declarations from both
   * , to account for both the declaratons that were deleted and those that
   * are newly created. Then we use the deptable to figure out the files
   * that referred to them. Finally we recheck the lot.
   * Args:
   *
   * genv, env : environments
   * old_fast: old file-ast from saved state
   * fast: newly parsed file ast
   * dirty_files: we need to typecheck these and,
   *    since their decl have changed, also all of their dependencies
   * similar_files: we only need to typecheck these,
   *    not their dependencies since their decl are unchanged
   **)
  let type_check_dirty genv env old_fast fast dirty_files similar_files t =
    let start_time = Unix.gettimeofday () in
    let fast = get_dirty_fast old_fast fast dirty_files in
    let names = Relative_path.Map.fold fast ~f:begin fun _k v acc ->
      FileInfo.merge_names v acc
    end ~init:FileInfo.empty_names in
    let deps = get_all_deps names in
    let to_recheck = Typing_deps.get_files deps in
    (* We still need to typecheck files whose declarations did not change *)
    let to_recheck = Relative_path.Set.union to_recheck similar_files in
    let fast = extend_fast fast env.files_info to_recheck in
    let result = type_check genv env fast t in
    HackEventLogger.type_check_dirty start_time
      (Relative_path.Set.cardinal dirty_files);
    Hh_logger.log "ServerInit type_check_dirty count: %d"
      (Relative_path.Set.cardinal dirty_files);
    result

  let get_build_targets env =
    let untracked, tracked = BuildMain.get_live_targets env in
    let untracked =
      List.map untracked Relative_path.from_root in
    let tracked =
      List.map tracked Relative_path.from_root in
    Relative_path.set_of_list untracked, Relative_path.set_of_list tracked

  let get_state_future genv root state_future timeout =
    let state = state_future
    >>= with_loader_timeout timeout "wait_for_changes"
    >>= fun (
      saved_state_fn,
      corresponding_rev,
      dirty_files,
      old_saved,
      state_distance
    ) ->
    genv.wait_until_ready ();
    let root = Path.to_string root in
    let updates = genv.notifier_async () in
    let open ServerNotifierTypes in
    let updates = match updates with
      | Notifier_state_enter (name, _) ->
        (** We ignore the returned debut port result. This is unfortunate but
         * harmless (since we should be using write_opt everywhere and it is
         * crash-resilient and handles the Option for us anyway).
         *
         * We can't easily use the returned result and set the env.debug_port
         * without making it a mutable reference (gross), and we can't return
         * a new genv in this function because we're in the Error/Result
         * monad for the state. *)
        let _ = Debug_port.write_opt
        (Debug_event.Fresh_vcs_state name) genv.debug_port in
        SSet.empty
      | Notifier_state_leave _
      | Notifier_unavailable -> SSet.empty
      | Notifier_synchronous_changes updates
      | Notifier_async_changes updates -> updates in
    let updates = SSet.filter updates (fun p ->
      string_starts_with p root && ServerEnv.file_filter p) in
    let changed_while_parsing = Relative_path.(relativize_set Root updates) in
    Ok (saved_state_fn,
      corresponding_rev,
      dirty_files,
      changed_while_parsing,
      old_saved,
      state_distance)
    in
    state

    (* If we fail to load a saved state, fall back to typechecking everything *)
    let fallback_init genv env err =
      SharedMem.cleanup_sqlite ();
      if err <> No_loader then begin
        let err_str = load_mini_exn_to_string err in
        HackEventLogger.load_mini_exn err_str;
        Hh_logger.log "Could not load mini state: %s" err_str;
      end;
      let get_next, t = indexing genv in
      let env, t = parsing ~lazy_parse:true genv env ~get_next t in
      SearchServiceRunner.update_fileinfo_map env.files_info;
      let t = update_files genv env.files_info t in
      let env, t = naming env t in
      let fast = FileInfo.simplify_fast env.files_info in
      let failed_parsing = Errors.get_failed_files env.errorl Errors.Parsing  in
      let fast = Relative_path.Set.fold failed_parsing
        ~f:(fun x m -> Relative_path.Map.remove m x) ~init:fast in
      type_check genv env fast t

end

type saved_state_fn = string
type corresponding_rev = Hg.rev
(** Newer versions of load script also output the distance of the
 * saved state's revision to the node's merge base. *)
type state_distance = int option

type state_result =
 (saved_state_fn * corresponding_rev * Relative_path.Set.t
   * Relative_path.Set.t * FileInfo.saved_state_info * state_distance, exn)
 result

(* Laziness *)
type lazy_level = Off | Decl | Parse | Init | Incremental

module type InitKind = sig
  val init :
    load_mini_approach:(load_mini_approach, exn) result ->
    ServerEnv.genv ->
    lazy_level ->
    ServerEnv.env ->
    Path.t ->
    (ServerEnv.env * float) * state_result
end

(* Eager Initialization:
* hh_server can initialize either by typechecking the entire project (aka
* starting from a "fresh state") or by loading from a saved state and
* typechecking what has changed.
*
* If we start from a fresh state, we run the following phases:
*
*   Parsing -> Naming -> Type-decl(skipped if lazy_decl)-> Type-check
*
* If we are loading a state, we do
*
*   Run load script and parsing concurrently -> Naming -> Type-decl
*
* Then we typecheck only the files that have changed since the state was
* saved.
*
* This is done in fairly similar manner to the incremental update
* code in ServerTypeCheck. The key difference is that incremental mode
* can compare the files that it has just parsed with their old versions,
* thereby (in theory) recomputing the least amount possible. OTOH,
* ServerInit only has the latest version of each file, so it has to make
* the most conservative estimate about what to recheck.
*)
module ServerEagerInit : InitKind = struct
  open ServerInitCommon

  let init ~load_mini_approach genv lazy_level env root =
    (* Spawn this first so that it can run in the background while parsing is
     * going on. The script can fail in a variety of ways, but the resolution
     * is always the same -- we fall back to rechecking everything. Running it
     * in the Result monad provides a convenient way to locate the error
     * handling code in one place. *)
    let state_future =
     load_mini_approach >>= invoke_approach genv root ~tiny:false in
    let get_next, t = indexing genv in
    let lazy_parse = lazy_level = Parse in
    let env, t = parsing ~lazy_parse genv env ~get_next t in
    SearchServiceRunner.update_fileinfo_map env.files_info;

    let timeout = genv.local_config.SLC.load_mini_script_timeout in
    let state_future = state_future >>=
      with_loader_timeout timeout "wait_for_state"
    in

    let t = update_files genv env.files_info t in
    let env, t = naming env t in
    let fast = FileInfo.simplify_fast env.files_info in
    let failed_parsing = Errors.get_failed_files env.errorl Errors.Parsing in
    let fast = Relative_path.Set.fold failed_parsing
      ~f:(fun x m -> Relative_path.Map.remove m x) ~init:fast in
    let env, t =
      if lazy_level <> Off then env, t
      else type_decl genv env fast t in

    let state = get_state_future genv root state_future timeout in
    match state with
    | Ok (
      saved_state_fn,
      corresponding_rev,
      dirty_files,
      changed_while_parsing,
      old_saved,
      _state_distance) ->
      let old_fast = FileInfo.saved_to_fast old_saved in
      (* During eager init, we don't need to worry about tracked targets since
         they we end up parsing everything anyways
      *)
      let build_targets, _ = get_build_targets env in
      Hh_logger.log "Successfully loaded mini-state";
      let global_state = ServerGlobalState.save () in
      let loaded_event = Debug_event.Loaded_saved_state ({
        Debug_event.filename = saved_state_fn;
        corresponding_rev;
        dirty_files;
        changed_while_parsing;
        build_targets;
      }, global_state) in
      let () = Printf.eprintf "Sending Loaded_saved_state debug event\n%!" in
      let _ = Debug_port.write_opt loaded_event genv.debug_port in
      (* Build targets are untracked by version control, so we must always
       * recheck them. While we could query hg / git for the untracked files,
       * it's much slower. *)
      let dirty_files =
        Relative_path.Set.union dirty_files build_targets in
      (* If a file has changed while we were parsing, we may have parsed the
       * new version, so we must treat it as possibly creating new type
       * errors. *)
      let dirty_files =
        Relative_path.Set.union dirty_files changed_while_parsing in
      (* But we still want to keep it in the set of things that need to be
       * reparsed in the next round of incremental updates. *)
      let env = { env with
        disk_needs_parsing =
          Relative_path.Set.union env.disk_needs_parsing changed_while_parsing;
      } in
      type_check_dirty genv env old_fast fast dirty_files Relative_path.Set.empty t, state
    | Error err ->
      (* Fall back to type-checking everything *)
      SharedMem.cleanup_sqlite ();
      if err <> No_loader then begin
        let err_str = load_mini_exn_to_string err in
        HackEventLogger.load_mini_exn err_str;
        Hh_logger.log "Could not load mini state: %s" err_str;
      end;
      type_check genv env fast t, state
end

(* In an incremental init, we start by querying hg using hg cat
  to obtain the old versions of files that were loaded from the saved state.
  This vastly decreases the number of files we need to typecheck, since we can
  then compute the difference between the files and only typecheck files
  affected by the differences. In a regular lazy init, we would have to
  typecheck all of the dependencies and uses of extends dependencies of changed
  files, which is way more conservative and ends up taking a lot more time.
*)
module ServerIncrementalInit : InitKind = struct
  open ServerInitCommon

  (* Runs the hg cat process to query for the old versions of dirty files *)
  let send_hg_cat_command root rev dirty_file_paths_list t =
    let tmp_dir = (Relative_path.path_of_prefix Relative_path.Tmp) in
    (* First, we need to make the paths to mimic those in our repository. *)
    List.iter dirty_file_paths_list
      ~f:(fun path -> Sys_utils.mkdir_p (tmp_dir ^ (Filename.dirname path)));
    (* Grab the old version of files from hg *)
    let pid = Hg.get_old_version_of_files
      ~rev
      ~out: ( tmp_dir ^ "%p")
      ~files: dirty_file_paths_list
      ~repo: (Path.to_string root) in
    HackEventLogger.send_hg_end t;
    pid, Hh_logger.log_duration "Send hg cat command" t

  (* Wait for hg cat command to finish *)
  let wait_hg_cat pid t =
    (* Ensure hg command has finished *)
    begin
      match Future.get pid with
      | Error err ->
      (* Errors don't really matter here, at worst we are just parsing empty
        files and we'll get the real ones during incremental mode *)
      Hh_logger.log "Error with hg, continuing. Error: %s" (Future.error_to_string err);
      HackEventLogger.hg_cat_exn (Future.error_to_string err)
      | Ok () ->
        ()
    end;
    HackEventLogger.wait_hg_end t;
    Hh_logger.log_duration "Extra time waiting for hg cat" t


  let delete_tmp_directory t =
    let tmp_dir = (Relative_path.path_of_prefix Relative_path.Tmp) in
    ignore(rm_dir_tree_async tmp_dir);
    Hh_logger.log_duration "Deleting tmp directory" t


  let init ~load_mini_approach genv lazy_level env  root =
    assert (lazy_level = Incremental);
    let state_future =
      load_mini_approach >>= invoke_approach genv root ~tiny:false in

    let timeout = genv.local_config.SLC.load_mini_script_timeout in
    let state_future = state_future >>= fun f ->
      with_loader_timeout timeout "wait_for_state" f
    in

    let state = get_state_future genv root state_future timeout in
    match state with
    | Ok (
      saved_state_fn, corresponding_rev,
      dirty_files, changed_while_parsing, old_saved, _state_distance) ->
      let build_targets, tracked_targets = get_build_targets env in
      Hh_logger.log "Successfully loaded mini-state";
      let global_state = ServerGlobalState.save () in
      let loaded_event = Debug_event.Loaded_saved_state ({
        Debug_event.filename = saved_state_fn;
        corresponding_rev;
        dirty_files;
        changed_while_parsing;
        build_targets;
      }, global_state) in
      Hh_logger.log "Sending Loaded_saved_state debug event\n";
      let _ = Debug_port.write_opt loaded_event genv.debug_port in
      let t = Unix.gettimeofday () in
      (* Grab all the files that have changed since the base revision *)
      let dirty_files =
        Relative_path.Set.union dirty_files changed_while_parsing in
      let dirty_file_list =
        Relative_path.Set.elements dirty_files in
      let dirty_file_paths_list =
        List.map dirty_file_list (Relative_path.suffix) in
      (* Send the hg cat command *)
      let pid, t = send_hg_cat_command
        root corresponding_rev dirty_file_paths_list t in
      (* Find the temporary directories *)
      let tmp_files_list = List.map ~f:Relative_path.to_tmp dirty_file_list in
      (* Build targets are untracked by version control, so we must always
       * recheck them. While we could query hg / git for the untracked files,
       * it's much slower. *)
      let dirty_files_and_build_targets =
        Relative_path.Set.union dirty_files build_targets in
      let old_hack_files = FileInfo.saved_to_hack_files old_saved in
      let old_info = FileInfo.saved_to_info old_saved in
      (* Run global naming on the old file info object *)
      let t = naming_with_fast old_hack_files t in
      let t = update_search old_saved t in
      let t = wait_hg_cat pid t in
      (*
        Tracked targets are build files that are tracked by version control.
        We don't need to typecheck them, but we do need to parse them to load
        them into memory, since arc rebuild deletes them before running.
        This avoids build step dependencies and file_heap_stale errors crashing
        the server when build fails and the deleted files aren't properly
        regenerated.
      *)
      let parsing_files_list =
        (Relative_path.Set.elements tracked_targets) @ tmp_files_list in
      let next = MultiWorker.next genv.workers parsing_files_list in
      (* During parsing, we parse the temp files as if they were the real
        ones they refer to *)
      let env, t = parsing genv env ~lazy_parse:true ~get_next:next t in
      let fast = FileInfo.simplify_fast env.files_info in
      (* Declare the types of just the dirty files *)
      let env, t = type_decl genv env fast t in
      let env = { env with
        disk_needs_parsing =
          Relative_path.Set.union env.disk_needs_parsing changed_while_parsing;
      } in
      let env = { env with
        files_info= old_info;
      } in
      (* The original dirty files and build targets need to be rechecked *)
      let env = { env with
        disk_needs_parsing = Relative_path.Set.union
          env.disk_needs_parsing dirty_files_and_build_targets
      } in
      let t = update_files genv env.files_info t in
      let t = delete_tmp_directory t in
      let env, _, _ =
        ServerTypeCheck.type_check genv env ServerTypeCheck.Full_check in
      (env, t), state
    | Error err ->
      fallback_init genv env err, state

end

(* Lazy Initialization:
 * During Lazy initialization, hh_server tries to do as little work as possible.
 * If we load from saved state, our steps are:
 * Load from saved state -> Parse dirty files -> Naming -> Dirty Typecheck
 * Otherwise, we fall back to the original with lazy decl and parse turned on:
 * Full Parsing -> Naming -> Full Typecheck
 *)
module ServerLazyInit : InitKind = struct
  open ServerInitCommon

  let init ~load_mini_approach genv lazy_level env root =
    assert(lazy_level = Init);
    Hh_logger.log "Begin loading mini-state";
    let tiny = genv.local_config.SLC.load_tiny_state in
    let state_future =
      load_mini_approach >>= invoke_approach genv root ~tiny in
    let timeout = genv.local_config.SLC.load_mini_script_timeout in
    let state_future = state_future >>= fun f ->
      with_loader_timeout timeout "wait_for_state" f
    in

    let state = get_state_future genv root state_future timeout in

    match state with
    | Ok (
      saved_state_fn, corresponding_rev,
      dirty_files, changed_while_parsing, old_saved, _state_distance) ->
      let build_targets, tracked_targets = get_build_targets env in
      Hh_logger.log "Successfully loaded mini-state";
      let global_state = ServerGlobalState.save () in
      let loaded_event = Debug_event.Loaded_saved_state ({
        Debug_event.filename = saved_state_fn;
        corresponding_rev;
        dirty_files;
        changed_while_parsing;
        build_targets;
      }, global_state) in
      Hh_logger.log "Sending Loaded_saved_state debug event\n";
      let _ = Debug_port.write_opt loaded_event genv.debug_port in
      let t = Unix.gettimeofday () in
      (* Build targets are untracked by version control, so we must always
       * recheck them. While we could query hg / git for the untracked files,
       * it's much slower. *)
      let dirty_files =
        Relative_path.Set.union dirty_files build_targets in
      let dirty_files =
        Relative_path.Set.union dirty_files changed_while_parsing in
      (*
        Tracked targets are build files that are tracked by version control.
        We don't need to typecheck them, but we do need to parse them to load
        them into memory, since arc rebuild deletes them before running.
        This avoids build step dependencies and file_heap_stale errors crashing
        the server when build fails and the deleted files aren't properly
        regenerated.
      *)
      let parsing_files =
        Relative_path.Set.union dirty_files tracked_targets in
      let parsing_files_list = Relative_path.Set.elements parsing_files in
      let old_fast = FileInfo.saved_to_fast old_saved in

      (* Get only the hack files for global naming *)
      let old_hack_files = FileInfo.saved_to_hack_files old_saved in
      let old_info = FileInfo.saved_to_info old_saved in
      (* Parse dirty files only *)
      let next = MultiWorker.next genv.workers parsing_files_list in
      let env, t = parsing genv env ~lazy_parse:true ~get_next:next
        ~count:(List.length parsing_files_list) t in
      SearchServiceRunner.update_fileinfo_map env.files_info;

      let t = update_files genv env.files_info t in
      (* Name all the files from the old fast (except the new ones we parsed) *)
      let old_hack_names = Relative_path.Map.filter old_hack_files (fun k _v ->
          not (Relative_path.Set.mem parsing_files k)
        ) in

      let t = naming_with_fast old_hack_names t in
      (* Do global naming on all dirty files *)
      let env, t = naming env t in

      (* Add all files from fast to the files_info object *)
      let fast = FileInfo.simplify_fast env.files_info in
      let failed_parsing = Errors.get_failed_files env.errorl Errors.Parsing in
      let fast = Relative_path.Set.fold failed_parsing
        ~f:(fun x m -> Relative_path.Map.remove m x) ~init:fast in

      let env = { env with
        disk_needs_parsing =
          Relative_path.Set.union env.disk_needs_parsing changed_while_parsing;
      } in

      (* Separate the dirty files from the files whose decl only changed *)
      (* Here, for each dirty file, we compare its hash to the one saved
      in the saved state. If the hashes are the same, then the declarations
      on the file have not changed and we only need to retypecheck that file,
      not all of its dependencies.
      We call these files "similar" to their previous versions. *)
      let similar_files, dirty_files = Relative_path.Set.partition
      (fun f ->
          let info1 = Relative_path.Map.get old_info f in
          let info2 = Relative_path.Map.get env.files_info f in
          match info1, info2 with
          | Some x, Some y ->
            (match x.FileInfo.hash, y.FileInfo.hash with
            | Some x, Some y ->
              Digest.equal x y
            | _ ->
              false)
          | _ ->
            false
        ) dirty_files in

      let env = { env with
        files_info=Relative_path.Map.union env.files_info old_info;
      } in
      (* Update the fileinfo object's dependencies now that we have full fast *)
      let t = update_files genv env.files_info t in

      let t = update_search old_saved t in

      type_check_dirty genv env old_fast fast dirty_files similar_files t, state
    | Error err ->
      (* Fall back to type-checking everything *)
      fallback_init genv env err, state
end


let ai_check genv files_info env t =
  match ServerArgs.ai_mode genv.options with
  | Some ai_opt ->
    let failed_parsing, failed_decl, failed_check =
      Errors.get_failed_files env.errorl Errors.Parsing,
      Errors.get_failed_files env.errorl Errors.Decl,
      Errors.get_failed_files env.errorl Errors.Typing
    in
    let all_passed = List.for_all
      [failed_parsing; failed_decl; failed_check;]
      (fun m -> Relative_path.Set.is_empty m) in
    if not all_passed then begin
      Hh_logger.log "Cannot run AI because of errors in source";
      env, t
    end
    else begin
      let check_mode = ServerArgs.check_mode genv.options in
      let errorl = Ai.go
          Typing_check_utils.check_defs genv.workers files_info
          env.tcopt ai_opt check_mode in
      let env = { env with
                  errorl = Errors.merge errorl env.errorl;
                } in
      env, (Hh_logger.log_duration "Ai" t)
    end
  | None -> env, t

let run_search genv t =
  if SearchServiceRunner.should_run_completely genv
  then begin
    (* The duration is already logged by SearchServiceRunner *)
    SearchServiceRunner.run_completely genv;
    HackEventLogger.update_search_end t
  end
  else ()

let save_state env fn =
  let t = Unix.gettimeofday () in
  if not (Errors.is_empty env.errorl)
  then failwith "--save-mini only works if there are no type errors!";
  let chan = Sys_utils.open_out_no_fail fn in
  let saved = FileInfo.info_to_saved env.files_info in
  Marshal.to_channel chan saved [];
  Sys_utils.close_out_no_fail fn chan;
  let sqlite_save_t = SharedMem.save_dep_table_sqlite (fn^".sql") Build_id.build_revision in
  Hh_logger.log "Saving deptable using sqlite took(seconds): %d" sqlite_save_t;
  ignore @@ Hh_logger.log_duration "Saving" t

let gen_deps genv env t =
  let files_list = Relative_path.Map.keys env.files_info in
  let next = MultiWorker.next genv.workers files_list in
  Dependency_service.go
    genv.workers
    ~get_next:next
    env.popt;
  Hh_logger.log_duration "Generating dependencies" t


let get_lazy_level genv =
  let lazy_decl = Option.is_none (ServerArgs.ai_mode genv.options) in
  let lazy_parse = genv.local_config.SLC.lazy_parse in
  let lazy_initialize = genv.local_config.SLC.lazy_init in
  let incremental_init = genv.local_config.SLC.incremental_init in
  match lazy_decl, lazy_parse, lazy_initialize, incremental_init with
  | true, false, false, false -> Decl
  | true, true, false, false -> Parse
  | true, true, true, false -> Init
  | true, true, true, true -> Incremental
  | _ -> Off


(* Initialize only to save a saved state *)
let init_to_save_state genv =
  let open ServerInitCommon in
  let env = ServerEnvBuild.make_env genv.config in
  let get_next, t = indexing genv in
  (* We need full asts to generate dependencies *)
  let env, t = parsing ~lazy_parse:false genv env ~get_next t in
  let t = update_files genv env.files_info t in
  let env, t = naming env t in
  ignore(gen_deps genv env t);
  env


(* entry point *)
let init ?load_mini_approach genv =
  let lazy_lev = get_lazy_level genv in
  let load_mini_approach = Core_result.of_option load_mini_approach
    ~error:No_loader in
  let env = ServerEnvBuild.make_env genv.config in
  let root = ServerArgs.root genv.options in
  let (env, t), state =
    match lazy_lev with
    | Incremental ->
      ServerIncrementalInit.init ~load_mini_approach genv lazy_lev env root
    | Init ->
      ServerLazyInit.init ~load_mini_approach genv lazy_lev env root
    | _ ->
      ServerEagerInit.init ~load_mini_approach genv lazy_lev env root
  in
  let env, t = ai_check genv env.files_info env t in
  run_search genv t;
  SharedMem.init_done ();
  ServerUtils.print_hash_stats ();
  let result = match state with
    | Ok (
      _saved_state_fn,
      _corresponding_rev,
      _dirty_files,
      _changed_while_parsing,
      _old_saved,
      state_distance) ->
        Mini_load state_distance
    | Error (Future.Failure e) ->
      Mini_load_failed (Future.error_to_string e)
    | Error e ->
      Mini_load_failed (Printexc.to_string e)
  in
  env, result
