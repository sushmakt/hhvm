(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Hh_core
open Integration_test_base_types
open Reordered_argument_collections
open ServerCommandTypes
open SearchServiceRunner

let root = "/"
let hhi = "/hhi"
let () = Hh_logger.Level.set_min_level Hh_logger.Level.Off
let server_config = ServerEnvBuild.default_genv.ServerEnv.config
let global_opts = GlobalOptions.make
  ~tco_assume_php: false
  ~tco_safe_array: false
  ~tco_safe_vector_array: false
  ~tco_user_attrs: None
  ~tco_experimental_features: GlobalOptions.tco_experimental_all
  ~tco_migration_flags: SSet.empty
  ~po_auto_namespace_map: []
  ~po_deregister_php_stdlib:true
  ~tco_disallow_destruct:false
  ~tco_disallow_ambiguous_lambda:false
  ~ignored_fixme_codes: ISet.empty

let server_config = ServerConfig.set_tc_options server_config global_opts
let server_config = ServerConfig.set_parser_options
  server_config global_opts

let genv = ref { ServerEnvBuild.default_genv with
  ServerEnv.config = server_config
}

(* Hhi files are loaded during server setup. If given a list of string + contents, we add them
to the test disk and add them to disk_needs_parsing. After one server run loop, they will be loaded.
This isn't exactly the same as how initialization does it, but the purpose is not to test the hhi
files, but to test incremental mode behavior with Hhi files present.
*)
let setup_server ?custom_config ?(hhi_files = []) ()  =
  Printexc.record_backtrace true;
  EventLogger.init EventLogger.Event_logger_fake 0.0;
  Relative_path.set_path_prefix Relative_path.Root (Path.make root);
  Relative_path.set_path_prefix Relative_path.Hhi (Path.make hhi);
  let _ = SharedMem.init GlobalConfig.default_sharedmem_config in

  List.iter hhi_files ~f:(fun (fn, contents) ->
    TestDisk.set (Filename.concat hhi fn) contents
  );

  let result = match custom_config with
  | Some config -> ServerEnvBuild.make_env config
  | None -> ServerEnvBuild.make_env !genv.ServerEnv.config in
  let hhi_file_list = List.map hhi_files ~f:(fun (fn, _) ->
    Relative_path.create (Relative_path.Hhi) (Filename.concat hhi fn)) in
  let hhi_set = Relative_path.Set.of_list hhi_file_list in
  { result with ServerEnv.disk_needs_parsing = hhi_set }


let default_loop_input = {
  disk_changes = [];
  new_client = None;
  persistent_client_request = None;
}

let run_loop_once : type a b. ServerEnv.env -> (a, b) loop_inputs ->
    (ServerEnv.env * (a, b) loop_outputs) = fun env inputs ->
  TestClientProvider.clear();
  Option.iter inputs.new_client (function
  | RequestResponse x ->
    TestClientProvider.mock_new_client_type Non_persistent;
    TestClientProvider.mock_client_request x
  | ConnectPersistent ->
    TestClientProvider.mock_new_client_type Persistent);

  Option.iter inputs.persistent_client_request
    TestClientProvider.mock_persistent_client_request;

  let client_provider = ClientProvider.provider_for_test () in

  let disk_changes =
    List.map inputs.disk_changes (fun (x, y) -> root ^ x, y) in

  List.iter disk_changes
    (fun (path, contents) -> TestDisk.set path contents);

  let did_read_disk_changes_ref = ref false in

  let notifier () =
    if not !did_read_disk_changes_ref then begin
      did_read_disk_changes_ref := true;
      SSet.of_list (List.map disk_changes fst)
    end else SSet.empty
  in

  let genv = { !genv with
    ServerEnv.notifier_async =
      (fun () ->
        ServerNotifierTypes.Notifier_synchronous_changes (notifier ()));
    ServerEnv.notifier = notifier;
  } in

  (* Always pick up disk changes in tests immediately *)
  let env = ServerEnv.({ env with last_notifier_check_time = 0.0 }) in

  let env = ServerMain.serve_one_iteration genv env client_provider in
  SearchServiceRunner.run_completely genv;
  env, {
    did_read_disk_changes = !did_read_disk_changes_ref;
    rechecked_count =
      env.ServerEnv.recent_recheck_loop_stats.ServerEnv.rechecked_count;
    new_client_response =
      TestClientProvider.get_client_response Non_persistent;
    persistent_client_response =
      TestClientProvider.get_client_response Persistent;
    push_message = TestClientProvider.get_push_message ();
  }

let prepend_root x = root ^ x

let fail x =
  print_endline x;
  Printexc.(get_callstack 100 |> print_raw_backtrace stderr);
  exit 1

(******************************************************************************(
 * Utility functions to help format/throw errors for informative errors
)******************************************************************************)
let indent_string_with (indent : string) (error : string) : string =
  indent ^ String.concat ("\n" ^ indent) Str.(split (regexp "\n") error)
let indent_strings_with (indent : string) (errors : string list) : string =
  String.concat "" @@ List.map ~f:(indent_string_with indent) errors
let fail_on_none (error : string) optional_thing =
  match optional_thing with
  | None -> fail error
  | Some _ -> ()
let assert_responded (error : string) loop_output =
  fail_on_none error loop_output.persistent_client_response

let assertEqual expected got =
  let expected = String.trim expected in
  let got = String.trim got in
  if expected <> got then fail
    (Printf.sprintf "Expected:\n%s\nGot:\n%s\n" expected got)

let setup_disk env disk_changes =
  let env, loop_output = run_loop_once env { default_loop_input with
    disk_changes
  } in
  if not loop_output.did_read_disk_changes then
    fail "Expected the server to process disk updates";
  env

let connect_persistent_client env =
  let env, _ = run_loop_once env { default_loop_input with
    new_client = Some ConnectPersistent
  } in
  fail_on_none "Expected persistent client to be connected"
    env.ServerEnv.persistent_client;
  env

let get_errors env = Errors.get_error_list env.ServerEnv.errorl

let assert_no_errors env =
  match get_errors env with
  | [] -> ()
  | errors ->
    let errors_str =
      errors
      |> List.map ~f:Errors.to_list
      |> List.concat
      |> List.map ~f:(fun (_, e) -> e)
      |> List.fold_left ~init:"" ~f:(fun l1 l2 -> l1 ^ "\n" ^ l2)
    in
    fail (Printf.sprintf "Expected no errors, instead had:%s" errors_str)

let assertSingleError expected err_list =
  let error_strings =
    List.map ~f:(fun x -> Errors.(to_string (to_absolute x))) err_list
  in
  match error_strings with
  | [x] -> assertEqual expected x
  | _ ->
    let err_count = List.length err_list in
    let fmt_expected = indent_string_with " < " expected in
    let fmt_actual = indent_strings_with " > " error_strings in
    let msg = Printf.sprintf
"Expected to have exactly one error, namely:

%s

... but got %d errors...

%s
"
      fmt_expected
      err_count
      fmt_actual
    in
    fail msg

let subscribe_diagnostic ?(id=4) env =
  let env, _ = run_loop_once env { default_loop_input with
    persistent_client_request = Some (
      SUBSCRIBE_DIAGNOSTIC id
    )
  } in
  fail_on_none "Expected to subscribe to push diagnostics"
    env.ServerEnv.diag_subscribe;
  env

let open_file env ?contents file_name =
  let file_name = root ^ file_name in
  let contents = match contents with
    | Some contents -> contents
    | _ -> TestDisk.get file_name
  in
  let env, loop_output = run_loop_once env { default_loop_input with
    persistent_client_request = Some (OPEN_FILE (file_name, contents))
  } in
  assert_responded "Expected OPEN_FILE to be processeded" loop_output;
  env

let edit_file env name contents =
  let env, loop_output = run_loop_once env { default_loop_input with
    persistent_client_request = Some (EDIT_FILE
      (root ^ name, [{Ide_api_types.range = None; text = contents;}])
    )
  } in
  assert_responded "Expected EDIT_FILE to be processed" loop_output;
  env, loop_output

let close_file env name =
  let env, loop_output = run_loop_once env { default_loop_input with
    persistent_client_request = Some (CLOSE_FILE (root ^ name))
  } in
  assert_responded "Expected CLOSE_FILE to be processeded" loop_output;
  env, loop_output

let wait env =
  (* We simulate waiting one second since last command by manipulating
   * last_command_time. Will not work on timers that compare against other
   * counters. *)
  ServerEnv.{ env with last_command_time = env.last_command_time -. 1.0 }

let autocomplete env contents =
  run_loop_once env { default_loop_input with
    persistent_client_request = Some (AUTOCOMPLETE contents)
  }

let ide_autocomplete env (path, line, column) =
  let delimit_on_namespaces = false in
  run_loop_once env { default_loop_input with
    persistent_client_request = Some (IDE_AUTOCOMPLETE
      (root ^ path, Ide_api_types.{line; column}, delimit_on_namespaces)
    )
  }

let status ?(ignore_ide=false) env =
  run_loop_once env { default_loop_input with
    new_client = Some (RequestResponse (ServerCommandTypes.STATUS ignore_ide))
  }

let assert_no_diagnostics loop_output =
  match loop_output.push_message with
  | Some (DIAGNOSTIC _) ->
    fail "Did not expect to receive push diagnostics."
  | Some NEW_CLIENT_CONNECTED ->
    fail "Unexpected push message"
  | _ -> ()

let assert_has_diagnostics loop_output =
  match loop_output.push_message with
  | Some DIAGNOSTIC _ -> ()
  | Some BUSY_STATUS s ->
    let msg =
      match s with
      | Needs_local_typecheck -> "Needs_local_typecheck"
      | Doing_local_typecheck -> "Doing_local_typecheck"
      | Done_local_typecheck -> "Done_local_typecheck"
      | Doing_global_typecheck -> "Doing_global_typecheck"
      | Done_global_typecheck -> "Done_global_typecheck"
    in
    let msg =
      Printf.sprintf "Expected DIAGNOSTIC, but got BUSY_STATUS %s." msg
    in
    fail msg
  | Some NEW_CLIENT_CONNECTED ->
    fail "Expected DIAGNOSTIC, but got NEW_CLIENT_CONNECTED."
  | Some FATAL_EXCEPTION e
  | Some NONFATAL_EXCEPTION e ->
    let msg = Printf.sprintf
      "Expected DIAGNOSTIC, but got NON/FATAL_EXCEPTION:\n%s"
      e.Marshal_tools.message
    in
    fail msg
  | None -> fail "Expected to receive push diagnostics."

let errors_to_string buf x =
  List.iter x ~f: begin fun error ->
    Printf.bprintf buf "%s\n" (Errors.to_string error)
  end

let assert_errors errors expected =
  let buf = Buffer.create 1024 in
  (Errors.get_error_list errors)
  |> List.map ~f:(Errors.to_absolute) |> errors_to_string buf;
  assertEqual expected (Buffer.contents buf)

let assert_env_errors env expected =
  assert_errors env.ServerEnv.errorl expected

let diagnostics_to_string x =
  let buf = Buffer.create 1024 in
  SMap.iter x ~f:begin fun path errors ->
    Printf.bprintf buf "%s:\n" path;
    errors_to_string buf errors;
  end;
  Buffer.contents buf

let errors_to_string x =
  let buf = Buffer.create 1024 in
  errors_to_string buf x;
  Buffer.contents buf

let get_diagnostics loop_output =
  match loop_output.push_message with
  | Some (DIAGNOSTIC (_, m)) -> m
  | _ -> fail "Expected push diagnostics"

let assert_diagnostics loop_output expected =
  let diagnostics = get_diagnostics loop_output in
  let diagnostics_as_string = diagnostics_to_string diagnostics in
  assertEqual expected diagnostics_as_string

let assert_diagnostics_in loop_output filename expected =
  let diagnostics = get_diagnostics loop_output in
  let diagnostics = SMap.filter diagnostics
    ~f:(fun path _ -> path = prepend_root filename) in
  let diagnostics_as_string = diagnostics_to_string diagnostics in
  assertEqual expected diagnostics_as_string

let list_to_string l =
  let buf = Buffer.create 1024 in
  List.iter l ~f:(Printf.bprintf buf "%s ");
  Buffer.contents buf

let assert_autocomplete loop_output expected =
  let results = match loop_output.persistent_client_response with
    | Some res -> res
    | _ -> fail "Expected autocomplete response"
  in
  let results = results |> List.map ~f:(fun x -> x.AutocompleteTypes.res_name) in
  (* The autocomplete results out of hack are unsorted *)
  let results_as_string = results |> List.sort ~cmp:compare |> list_to_string in
  let expected_as_string = expected |> List.sort ~cmp:compare |> list_to_string in
  assertEqual expected_as_string results_as_string

let assert_ide_autocomplete loop_output expected =
  let results = match loop_output.persistent_client_response with
    | Some res -> res
    | _ -> fail "Expected autocomplete response"
  in
  let results = List.map results.AutocompleteTypes.completions
    ~f:(fun x -> x.AutocompleteTypes.res_name) in
  let results_as_string = list_to_string results in
  let expected_as_string = list_to_string expected in
  assertEqual expected_as_string results_as_string

let assert_status loop_output expected =
  let {Server_status.error_list; _} = match loop_output.new_client_response with
    | Some res -> res
    | _ -> fail "Expected status response"
  in
  let results_as_string = errors_to_string error_list in
  assertEqual expected results_as_string
