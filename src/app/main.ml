open StdLabels
open Lwt.Infix
open Cmdliner

module P = Usbmux.Protocol
module R = Usbmux.Relay
module U = Yojson.Basic.Util

let show_status port : unit =
  (* Ripped from cmdliner *)
  let find_cmd cmds =
    let test, null = match Sys.os_type with
      | "Win32" -> "where", " NUL"
      | _ -> "type", "/dev/null"
    in
    let cmd c = Sys.command (Printf.sprintf "%s %s 1>%s 2>%s" test c null null) = 0 in
    try Some (List.find ~f:cmd cmds) with Not_found -> None
  in
  let pager =
    let cmds = ["less"; "more"] in
    let cmds = try (Sys.getenv "PAGER") :: cmds with Not_found -> cmds in
    let cmds = try (Sys.getenv "MANPAGER") :: cmds with Not_found -> cmds in
    find_cmd cmds
  in
  Lwt_main.run begin
    try%lwt
      R.status ~port >>= fun as_json ->
      let (uptime, payload, lazy_exns,
           tunnels_created, tunnel_timeouts, mapping_file) =
        U.(member "uptime" as_json |> to_float,
           member "status_data" as_json,
           member "async_exceptions_count" as_json |> to_int,
           member "tunnels_created_count" as_json |> to_int,
           member "tunnel_timeouts" as_json |> to_int,
           member "mappings_file" as_json |> to_string)
      in
      let msg =
        Printf.(
          sprintf "%s\n%s\n%s\n%s\n%s\n%s"
            (sprintf "Uptime -> \n\tHours: %.2f \n\tMinutes: %.2f"
               (uptime /. 60.0 /. 60.0)
               (uptime /. 60.0))
            (sprintf "Useful Info -> \n\tLazy value exns: %d\
                      \n\tTunnels Created: %d\n\tTunnel Timeouts: %d\
                      \n\tReady Tunnels: %d"
               lazy_exns
               tunnels_created
               tunnel_timeouts
               (U.to_list payload |> List.length))
            (sprintf "Referencing mapping file at -> \n\t%s\n" mapping_file)
            ("Assuming that your devices are connected and your mapping \n\
              file has devices mapped to port 22 then you can \
              \nssh into them with the port numbers printed \
              below.\n\nExample:")
            ("\tssh root@localhost -p <some_port>")
            (Yojson.Basic.pretty_to_string payload)
        )
      in
      match pager with
      | None -> Lwt_io.printl msg
      | Some p ->
        let f_name = Filename.temp_file "gandalf" "status" in
        (fun oc -> Lwt_io.write_from_string_exactly oc msg 0 (String.length msg))
        |> Lwt_io.with_file ~mode:Lwt_io.Output f_name >>
        (Sys.command (Printf.sprintf "%s %s" p f_name) |> ignore;
         Lwt_unix.unlink f_name)
    with Unix.Unix_error(Unix.ECONNREFUSED, _, _) ->
      Lwt_io.printl "Error: Couldn't get status, check if \
                     gandalf is running (Also did you start gandalf \
                     with --status_port?)" >>
      exit 6
  end;
  exit 0

let create_pid_file () =
  (* This should use lockf *)
  Unix.(
    try
      let open_pid_file =
        openfile Usbmux.pid_file [O_RDWR; O_CREAT; O_CLOEXEC] 0o666
      in
      let current_pid = getpid () |> string_of_int in
      write open_pid_file current_pid 0 (String.length current_pid) |> ignore;
      close open_pid_file
    with Unix_error(EACCES, _, _) ->
      Printf.sprintf
        "Error: Couldn't open pid file %s, make sure you have right permissions"
        Usbmux.pid_file
      |> prerr_endline;
      exit 4
  )

let begin_program
    very_loud
    port_pairs
    do_daemonize
    do_reload_mapping
    do_status
    tunnel_timeout
    do_exit
    log_conns
    log_async_exn
    log_plugged_inout
    log_everything_else
    stats_server
    ignore_unix_exn_
    bind_host =
  let starting_place = Sys.getcwd () in
  if do_daemonize then begin
    (* This order matters, must get this done before anything Lwt
       related *)
    Lwt_daemon.daemonize ~syslog:true ();
    (* Ensure daemon has time to setup *)
    Unix.sleep 1
      (* Might require super user permissions *)
    |> create_pid_file
  end;
  if do_exit then R.(perform Shutdown);
  begin
    if do_reload_mapping then
      try R.(perform Reload)
      with Sys_error _ ->
        (Printf.sprintf "Error: Could not open pid file, are you \
                         sure gandalf was already running?")
        |> prerr_endline;
        exit 5
  end;
  (match (do_status, stats_server) with
   | (true, Some port) -> show_status port
   | _ -> ());
  Lwt.catch (fun () ->
      (* Now we start spinning up Lwt threads *)
      match port_pairs with
      | None ->
        if do_daemonize
        then "Warning: Only in listen mode, not daemonizing" |> prerr_endline;
        P.(create_listener ~event_cb:(function
            | Event Attached {serial_number = s; connection_speed = _;
                              connection_type = _; product_id = _;
                              location_id = _; device_id = d} ->
              Lwt_io.printlf "Device %d with serial number: %s connected" d s
            | Event Detached d -> Lwt_io.printlf "Device %d disconnected" d
            | _ -> Lwt.return ())
            ())
      | Some device_map ->
        let device_map =
          if Filename.is_relative device_map
          then Printf.sprintf "%s/%s" starting_place device_map
          else device_map
        in
        Usbmux.Logging.(
          let relay_with =
            R.make_tunnels
              ~bind_host:bind_host
              ~ignore_unix_exn:ignore_unix_exn_
              ?stats_server
              ?tunnel_timeout
              ~device_map
          in
          if very_loud
          then relay_with
              ~log_opts:{log_conns = true;
                         log_async_exn = true;
                         log_plugged_inout = true;
                         log_everything_else = true}
          else relay_with
              ~log_opts:{log_conns; log_async_exn;
                         log_plugged_inout; log_everything_else})
    )
    (fun exn -> Unix.(match exn with
         | Unix_error((ECONNREFUSED | ENOENT), _, _) ->
           Lwt_io.printl "Error: Check if usbmuxd is running" >>
           exit 7
         | R.Mapping_file_error s ->
           Lwt_io.printl s >>
           exit 8
         | Failure reason ->
           reason
           |> Lwt_io.printlf "Error: %s HINT: You most likely have \
                              poorly formed JSON, like a trailing comma." >>
           exit 8
         | e ->
           Printexc.to_string e
           |> Lwt_io.printlf "Error: Please report: Unknown exception: %s" >>
           exit 10
       ))

let entry_point = let open Gandalf_args in
  Term.(pure
          begin_program
        $ be_verbose
        $ forward_connection_file
        $ do_daemonize
        $ reload_mapping
        $ status
        $ tunneling_timeout
        $ do_exit
        $ log_connections
        $ log_async_exceptions
        $ log_plugged_action
        $ log_everything_else
        $ status_server_port
        $ ignore_all_unix_errors
        $ bind_host)

let top_level_info =
  let doc = "Control TCP forwarding for iDevices" in
  let man = [`S "DESCRIPTION";
             `P "$(b,$(tname)) lets you port forward local ports to specific \
                 ports on your jailbroken iDevices like iPhone, iPad, iTouch \
                 over USB; think about the ssh use-case. You need to \
                 have the usbmuxd daemon running, on OS X this means you \
                 don't have to do anything but on Linux you need to \
                 install and run it.";
             `S "EXAMPLES";
             `P "1) See with realtime updates what devices are connected \
                 This will start up gandalf in listen mode, that is it \
                 will print out whenver a device connects or disconnects";
             `Pre "$(b,$(tname))";
             `P "2) Start with a mapping file such that # start comments and \
                 consists of an array of json objects with these fields, \
                 note that name can be null and is just a nickname for \
                 this tunnel, other fields are required.";
             `Pre "# This is a comment\n\
                   [{\"udid\":\"9cdfac9f74c5e18a6eff3611c0927df5cf4f2eca\", \
                   \"name\":\"i11\",\n  \
                   \"forwarding\": [{\"local_port\":2000, \"device_port\":22},\
                   \n\t\t\t  {\"local_port\":3000, \"device_port\":1122}]}]";
             `Pre "$(b,$(tname)) -m mapping_file";
             `P "2.1) Daemonize $(b,$(tname)) with the -d flag. *NOTE*: You \
                 might need to end up doing that under sudo as $(b,$(tname)) \
                 needs to make a pid file under /var/run. If daemonizing \
                 is failing, try running as root. After daemonzing, \
                 check the system log for debugging info";
             `P "3) See a pretty JSON representation of devices and \
                 their ports that are currently connected.";
             `Pre "$(b,$(tname)) -s";
             `P "4) Reload $(b,$(tname)) with a new set of mappings";
             `Pre "$(b,$(tname)) -r";
             `P "5) Cleanly exit $(b,$(tname)), note this might require \
                 super user permissions.";
             `Pre "$(b,$(tname)) -e";
             `S "GUIDELINE";
             `P "Be sure to check your system log for valuable \
                 debugging information, especially with -v";
             `S "EXIT CODES";
             `P "1 -> Exited because of an unhandled async exception, please report";
             `P "2 -> Exited because couldn't reload mapping or couldn't shutdown cleanly";
             `P "3 -> Exited because relay was already running according to pid file";
             `P "4 -> Exited because of permissions, couldn't open pid file";
             `P "5 -> Check if $(b,$(tname)) was already running";
             `P "6 -> Check if $(b,$(tname)) is even running";
             `P "7 -> Check if usbmuxd is running";
             `P "8 -> Error in mapping file, check your json";
             `P "9 -> Some kind of Unix error, most likely caused by usbmuxd, \
                 check misc section logs";
             `P "10 -> Unknown reason, please report";
             `S "AUTHOR";
             `P "Edgar Aroutiounian <edgar.factorial@gmail.com>"]
  in
  Term.info "gandalf" ~version:"1.3.2" ~doc ~man

let () =
  Printexc.record_backtrace true;
  match Term.eval (entry_point, top_level_info) with
  | `Ok program -> Lwt_main.run program
  | _ -> ()
