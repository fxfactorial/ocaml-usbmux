open Lwt.Infix

module B = Yojson.Basic
module U = Yojson.Basic.Util
module P = Printf

module Logging = struct

  type log_opts = { log_conns : bool;
                    log_async_exn : bool;
                    log_plugged_inout : bool;
                    log_everything_else : bool; }

  let (conn_section, async_exn, plugged_inout, everything_else) =
    Lwt_log.Section.make "connections",
    Lwt_log.Section.make "async_exceptions",
    Lwt_log.Section.make "plugged_inout",
    Lwt_log.Section.make "everything_else"

  let logging_opts =
    ref {log_conns = false; log_async_exn = false;
         log_plugged_inout = false; log_everything_else = false;}

  let () = Lwt_log.add_rule "*" Lwt_log.Info

end

let byte_swap_16 value =
  ((value land 0xFF) lsl 8) lor ((value lsr 8) land 0xFF)

let time_now () =
  Unix.(
    let localtime = localtime (time ()) in
    P.sprintf "[%02u:%02u:%02u]"
      localtime.tm_hour localtime.tm_min localtime.tm_sec
  )

let pid_file = "/var/run/gandalf.pid"

module Protocol = struct

  type msg_version_t = Binary | Plist

  type conn_code = Success
                 | Device_requested_not_connected
                 | Port_requested_not_available
                 | Malformed_request

  type event = Attached of device_t
             | Detached of int

  and device_t = { serial_number : string;
                   connection_speed : int;
                   connection_type : string;
                   product_id : int;
                   location_id : int;
                   device_id : int; }

  type msg_t = Result of conn_code
             | Event of event

  exception Unknown_reply of string

  let (header_length, usbmuxd_address) = 16, Unix.ADDR_UNIX "/var/run/usbmuxd"

  let listen_message =
    Plist.(Dict [("MessageType", String "Listen");
                 ("ClientVersionString", String "ocaml-usbmux");
                 ("ProgName", String "ocaml-usbmux")]
           |> make)

  (* Note: PortNumber must be network-endian, so it gets byte swapped here *)
  let connect_message ~device_id ~device_port =
    Plist.((Dict [("MessageType", String "Connect");
                  ("ClientVersionString", String "ocaml-usbmux");
                  ("ProgName", String "ocaml-usbmux");
                  ("DeviceID", Integer device_id);
                  ("PortNumber", Integer (byte_swap_16 device_port))])
           |> make)

  let msg_length msg = String.length msg + header_length

  let listen_msg_len = msg_length listen_message

  let read_header i_chan =
    i_chan |> Lwt_io.atomic begin fun ic ->
      Lwt_io.LE.(read_int32 ic >>= fun raw_count ->
                 read_int32 ic >>= fun raw_version ->
                 read_int32 ic >>= fun raw_request ->
                 read_int32 ic >|= fun raw_tag ->
                 Int32.(to_int raw_count,
                        to_int raw_version,
                        to_int raw_request,
                        to_int raw_tag))
    end

  (** Highly advised to only change value of version of default values *)
  let write_header ?(version=Plist) ?(request=8) ?(tag=1) ~total_len o_chan =
    o_chan |> Lwt_io.atomic begin fun oc ->
      ([total_len; if version = Plist then 1 else 0; request; tag]
       |> List.map Int32.of_int )
      |> Lwt_list.iter_s (Lwt_io.LE.write_int32 oc)
    end

  let parse_reply raw_reply =
    let handle = Plist.parse_dict raw_reply in
    U.(
      match member "MessageType" handle |> to_string with
      | "Result" -> (match member "Number" handle |> to_int with
          | 0 -> Result Success
          | 2 -> Result Device_requested_not_connected
          | 3 -> Result Port_requested_not_available
          | 5 -> Result Malformed_request
          | n -> raise (Unknown_reply (P.sprintf "Unknown result code: %d" n)))
      | "Attached" ->
        Event (Attached
                 {serial_number = member "SerialNumber" handle |> to_string;
                  connection_speed = member "ConnectionSpeed" handle |> to_int;
                  connection_type = member "ConnectionType" handle |> to_string;
                  product_id = member "ProductID" handle |> to_int;
                  location_id = member "LocationID" handle |> to_int;
                  device_id = member "DeviceID" handle |> to_int ;})
      | "Detached" -> Event (Detached (member "DeviceID" handle |> to_int))
      | otherwise -> raise (Unknown_reply otherwise))

  let create_listener ?event_cb () =
    Lwt_io.with_connection usbmuxd_address begin fun (mux_ic, mux_oc) ->
      (* Send the header for our listen message *)
      write_header ~total_len:listen_msg_len mux_oc >>
      ((String.length listen_message)
       |> Lwt_io.write_from_string_exactly mux_oc listen_message 0) >>
      read_header mux_ic >>= fun (msg_len, _, _, _) ->
      let buffer = Bytes.create (msg_len - header_length) in

      let rec start_listening () =
        read_header mux_ic >>= fun (msg_len, _, _, _) ->
        let buffer = Bytes.create (msg_len - header_length) in
        Lwt_io.read_into_exactly mux_ic buffer 0 (msg_len - header_length) >>
        match event_cb with
        | None -> start_listening ()
        | Some g -> g (parse_reply buffer) >>= start_listening
      in
      Lwt_io.read_into_exactly mux_ic buffer 0 (msg_len - header_length) >>
      match event_cb with
      | None -> start_listening ()
      | Some g -> g (parse_reply buffer) >>= start_listening
    end

end

module Relay = struct

  type action = Shutdown | Reload

  exception Bad_mapping_file of string

  let relay_lock = Lwt_mutex.create ()

  let (running_servers, mapping_file, relay_timeout) =
    Hashtbl.create 10, ref "", ref 0

  let status_server = Uri.of_string "http://127.0.0.1:5000"

  let relay_pid () =
    let open_pid_file = open_in pid_file in
    let target_pid = input_line open_pid_file |> int_of_string in
    close_in open_pid_file;
    target_pid

  let close_chans (ic, oc) () = Lwt_io.close ic >> Lwt_io.close oc

  let timeout_task ~after_timeout n =
    let t = fst (Lwt.task ()) in
    let timeout =
      Lwt_timeout.create n begin fun () ->
        Lwt.cancel t;
        after_timeout () |> Lwt.ignore_result
      end
    in
    Lwt_timeout.start timeout;
    Lwt.on_cancel t (fun () -> Lwt_timeout.stop timeout);
    t

  let timeout_stream ~after_timeout ~read_timeout stream =
    (fun () ->
       Lwt.pick
         (* Either get data off the stream or timeout after a period
            of time, we don't want to keep relays open that have no
            activity on them *)
         [Lwt_stream.get stream; timeout_task ~after_timeout read_timeout])
    |> Lwt_stream.from

  let echo read_timeout ic oc =
    Lwt_io.read_chars ic
    |> timeout_stream ~after_timeout:(close_chans (ic, oc)) ~read_timeout
    |> Lwt_io.write_chars oc

  let load_mappings file_name =
    Lwt_io.lines_of_file file_name |> Lwt_stream.to_list >|= fun all_names ->
    let prepped = all_names |> List.fold_left begin fun accum line ->
        if line <> "" then begin
          match (Stringext.trim_left line).[0] with
          (* Ignore comments *)
          | '#' -> accum
          | _ ->
            match Stringext.split line ~on:':' with
            | udid :: port_number :: port_forward :: [] ->
              (udid, int_of_string port_number, int_of_string port_forward) :: accum
            | _ ->
              raise (Bad_mapping_file "Mapping file needs to be of the \
                                       form udid:port_local:device_port")
        end
        else accum
      end []
    in
    let t = Hashtbl.create (List.length prepped) in
    prepped |> List.iter (fun (k, v, p_forward) -> Hashtbl.add t k (v, p_forward));
    t

  let do_tunnel tunnel_timeout (udid, (port, device_port, device_id)) =
    let open Protocol in
    let server_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
    let server =
      Lwt_io.establish_server server_address begin fun (tcp_ic, tcp_oc) ->
        Lwt_io.with_connection usbmuxd_address begin fun (mux_ic, mux_oc) ->
          let msg = connect_message ~device_id ~device_port in
          write_header ~total_len:(msg_length msg) mux_oc >>
          Lwt_io.write_from_string_exactly mux_oc msg 0 (String.length msg) >>
          (* Read the reply, should be good to start just raw piping *)
          read_header mux_ic >>= fun (msg_len, _, _, _) ->
          let buffer = Bytes.create (msg_len - header_length) in
          Lwt_io.read_into_exactly mux_ic buffer 0 (msg_len - header_length) >>
          match parse_reply buffer with
          | Result Success ->
            Logging.(
              if !logging_opts.log_conns
              then (
                Lwt_log.ign_info_f
                  ~section:conn_section
                  "Tunneling. Udid: %s Local Port: %d Device Port: %d \
                   Device_id: %d" udid port device_port device_id);
              (* Provide the tunneling with a partial function *)
              let e = echo tunnel_timeout in
              e tcp_ic mux_oc <&> e mux_ic tcp_oc >>
              if !logging_opts.log_conns
              then
                Lwt_log.info_f
                  ~section:conn_section
                  "Finished Tunneling. Udid: %s Port: %d Device Port: %d \
                   Device_id: %d" udid port device_port device_id
              else Lwt.return_unit
            )
          | Result Device_requested_not_connected ->
            Logging.(
              if !logging_opts.log_everything_else
              then
                Lwt_log.log_f
                  ~level:Lwt_log.Info
                  ~section:everything_else
                  "Tunneling: Device requested was not connected. \
                   Udid: %s Device_id: %d" udid device_id
              else Lwt.return_unit
            )
          | Result Port_requested_not_available ->
            Logging.(
              if !logging_opts.log_everything_else
              then
                Lwt_log.log_f
                  ~level:Lwt_log.Info
                  ~section:everything_else
                  "Tunneling. Port requested, %d, wasn't available. \
                   Udid: %s Port: %d Device_id: %d"
                  device_port udid port device_id
              else Lwt.return_unit
            )
          | _ -> Lwt.return_unit
        end
        (* Finished tunneling, now cleanly close the chans *)
        >>= close_chans (tcp_ic, tcp_oc)
        |> Lwt.ignore_result
      end
    in
    (* Register the server *)
    (fun () -> Lwt.return (Hashtbl.add running_servers device_id server))
    |> Lwt_mutex.with_lock relay_lock

  let complete_shutdown () =
    (* Kill the servers first *)
    running_servers |> Hashtbl.iter (fun _ tunnel -> Lwt_io.shutdown_server tunnel);
    Lwt_log.ign_info_f
      "Completed shutting down %d servers" (Hashtbl.length running_servers);
    Hashtbl.reset running_servers

  (* Note that this won't exit the program unless exit is explicitly
     called *)
  let () =
    Lwt.async_exception_hook := function
      | Lwt.Canceled ->
        Logging.(
          if !logging_opts.log_everything_else
          then
            Lwt_log.ign_info
              ~section:everything_else
              "A ssh connection timed out"
        )
      | Unix.Unix_error (UnixLabels.ENOTCONN, _, _) ->
        Logging.(
          if !logging_opts.log_everything_else
          then Lwt_log.ign_info ~section:everything_else "Connection refused"
        )
      | Unix.Unix_error(Unix.EADDRINUSE, _, _) ->
        Logging.(
          if !logging_opts.log_everything_else
          then
            Lwt_log.ign_info
              ~section:everything_else
              "Check if already running tunneling relay, probably are"
        )
      | exn ->
        Logging.(
          if !logging_opts.log_async_exn
          then
            Lwt_log.ign_info
              ~exn
              ~section:async_exn
              "Please report, this is an unhandled async exception (A bug)"
        );
        exit 4

  let device_alist_of_hashtable ~device_mapping ~devices =
    Hashtbl.fold begin fun device_id_key udid_value accum ->
      try
        let (from_port, to_port) = Hashtbl.find device_mapping udid_value in
        (udid_value, (from_port, to_port, device_id_key)) :: accum
      with
        Not_found ->
        Lwt_log.ign_info_f
          "Device with udid: %s expected but wasn't connected" udid_value;
        accum
    end
      devices []

  let start_status_server ~device_mapping ~devices =
    let device_list = ref (device_alist_of_hashtable ~device_mapping ~devices) in
    let start_time = Unix.gettimeofday () in
    let callback _ _ _ =
      let uptime = Unix.gettimeofday () -. start_time in
      let body =
        `Assoc [
          ("uptime", `Float uptime);
          ("mappings_file", `String !mapping_file);
          ("status_data",
           `List (!device_list
                  |> List.map begin fun (udid, (from_port, to_port, device_id)) ->
                    (`Assoc [("Local Port", `Int from_port);
                             ("iDevice Port Forwarded", `Int to_port);
                             ("Usbmuxd assigned iDevice ID", `Int device_id);
                             ("iDevice UDID", `String udid)] : B.json)
                  end))]
        |> B.to_string
      in
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body ()
    in
    let server = Cohttp_lwt_unix.Server.make ~callback () in

    (* Create another listener thread for updates to the devices
       listing, needed as device plugs in and out *)
    Lwt.async begin fun () ->
      let shutdown_and_prune d =
        Lwt_io.shutdown_server (Hashtbl.find running_servers d);
        Hashtbl.remove running_servers d
      in
      let spin_up_tunnel device_udid new_id =
        try
          let (port, device_port, _) = List.assoc device_udid !device_list in
          (device_udid, (port, device_port, new_id)) |> do_tunnel !relay_timeout
        with
          Not_found ->
          Logging.(
            if !logging_opts.log_everything_else
            then
              Lwt_log.info_f
                ~section:everything_else
                "relay can't create tunnel for device udid: %s" device_udid
            else Lwt.return_unit
          )
      in
      Protocol.(create_listener ~event_cb:begin function
          | Event Attached { serial_number = s; connection_speed = _;
                             connection_type = _; product_id = _;
                             location_id = _; device_id = d; } ->
            Logging.(
              if !logging_opts.log_plugged_inout
              then
                Lwt_log.ign_info_f
                  ~section:plugged_inout
                  "Device %d with serial number: %s connected" d s
            );
            if not (Hashtbl.mem devices d)
            then
              (* Two cases, devices that have been known or unknown devices *)
              load_mappings !mapping_file >|= fun device_mapping ->
              Hashtbl.add devices d s;
              device_list := device_alist_of_hashtable ~device_mapping ~devices;
              spin_up_tunnel s d |> Lwt.ignore_result
            else
              Lwt.return ()
          | Event Detached d ->
            Logging.(
              if !logging_opts.log_plugged_inout
              then
                Lwt_log.ign_info_f
                  ~section:plugged_inout
                  "Device %d disconnected" d
            );
            load_mappings !mapping_file >|= fun device_mapping ->
            Hashtbl.remove devices d;
            shutdown_and_prune d;
            device_list := device_alist_of_hashtable ~device_mapping ~devices
          | _ -> Lwt.return_unit
        end
          ())
    end;
    (* Status server also gets its own thread *)
    (fun () -> Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port 5000)) server)
    |> Lwt.async

  let rec begin_relay
      ?(log_opts=(!Logging.logging_opts))
      ?(stats_server=true)
      ~tunnel_timeout
      ~device_map =
    (* Set the logging options *)
    Logging.logging_opts := log_opts;
    (* Ask for larger internal buffers for Lwt_io function rather than
       the default of 4096 *)
    Lwt_io.set_default_buffer_size 32768;

    (* Set the tunneling timeouts *)
    relay_timeout := tunnel_timeout;

    (* Set the mapping file, need to hold this path so that when we
       reload, we know where to reload from *)
    mapping_file := device_map;

    (* Setup the signal handlers, needed so that we know when to
       reload, shutdown, etc. *)
    handle_signals tunnel_timeout;
    load_mappings !mapping_file >>= fun device_mapping ->
    let devices = Hashtbl.create 24 in
    try%lwt
      (* We do this because usbmuxd itself assigns device IDs and we
         need to begin the listen message, then find out the device IDs
         that usbmuxd has assigned per UDID, hence the timeout. *)
      Lwt.pick
        [Lwt_unix.timeout 1.0;
         Protocol.(create_listener ~event_cb:begin function
             | Event Attached { serial_number = s; connection_speed = _;
                                connection_type = _; product_id = _;
                                location_id = _; device_id = d; } ->
               Hashtbl.add devices d s |> Lwt.return
             | Event Detached d ->
               Hashtbl.remove devices d |> Lwt.return
             | _ -> Lwt.return_unit
           end
             ())]
    with
      Lwt_unix.Timeout ->
      (* Create, start a simple HTTP status server. We also register
         the at_exit function here because it ought to happen just
         once, like our status server *)
      if stats_server then begin
        start_status_server ~device_mapping ~devices;
        (fun () ->
           if Hashtbl.length running_servers <> 0
           then
             Lwt_io.printlf
               "Exited with %d still running; this is a bug."
               (Hashtbl.length running_servers)
           else Lwt.return_unit)
        |> Lwt_main.at_exit
      end;
      let rec forever () =
        (* This thread should never return but its better to be safe
           than sorry*)
        fst (Lwt.wait ()) >>= forever
      in
      (* Create, start the tunnels *)
      ((device_alist_of_hashtable ~device_mapping ~devices)
       |> Lwt_list.iter_p (do_tunnel tunnel_timeout)) >>
      (* Wait forever *)
      forever ()

  and do_restart tunnel_timeout =
    if Sys.file_exists !mapping_file then begin
      complete_shutdown ();
      Logging.(
        if !logging_opts.log_everything_else
        then Lwt_log.ign_info ~section:everything_else "Restarting relay with reloaded mappings"
      );
      (* Spin it up again *)
      begin_relay
        (* Use existing status server *)
        ~log_opts:!Logging.logging_opts
        ~stats_server:false
        ~tunnel_timeout
        ~device_map:!mapping_file
      |> Lwt.ignore_result
    end else
      Logging.(
        if !logging_opts.log_everything_else
        then Lwt_log.ign_info_f
            ~section:everything_else
            "Original mapping file %s does not exist \
             anymore, not reloading" !mapping_file
      )

  (* Mutually recursive function, handle_signals needs name of
     begin_relay and begin_relay needs the name handle_signals *)
  and handle_signals tunnel_timeout =
    Sys.([ (* Broken SSH pipes shouldn't exit our program *)
        signal sigpipe Signal_ignore;
        (* Stop the running threads, call begin_relay again *)
        signal
          sigusr1
          (Signal_handle (fun _ -> do_restart tunnel_timeout));
        (* Shutdown the servers, relays then exit *)
        signal sigusr2 (Signal_handle begin fun _ ->
            let relay_count = Hashtbl.length running_servers in
            complete_shutdown ();
            Logging.(
              if !logging_opts.log_everything_else
              then
                Lwt_log.ign_info_f
                  ~section:everything_else
                  "Shutdown %d relays, exiting now" relay_count;
              exit 0
            )
          end);
        (* Handle plain kill from command line *)
        signal sigterm (Signal_handle (fun _ -> complete_shutdown (); exit 0))
      ]) |> List.iter ignore

  (* We reload the mapping by sending a user defined signal to the
     current running daemon which will then cancel the running
     threads, i.e. the servers and connections, and reload from the
     original given mapping file. Or we just want to shutdown the
     servers and exit cleanly *)
  let perform action =
    Unix.(
      try
        let target_pid = relay_pid () in
        Sys.(match action with Reload -> sigusr1 | Shutdown -> sigusr2)
        |> kill target_pid;
        exit 0
      with
        Unix_error(EPERM, _, _) ->
        Logging.(
          if !logging_opts.log_everything_else
          then
            Lwt_log.ign_error ~section:everything_else
              (match action with Reload -> "Couldn't reload mapping, permissions error"
                               | Shutdown -> "Couldn't shutdown cleanly, \
                                              permissions error");
          exit 3
        )
      | Unix_error(ESRCH, _, _) ->
        Logging.(
          if !logging_opts.log_everything_else
          then
            Lwt_log.ign_error_f ~section:everything_else
              "Are you sure relay was running already? \
               Pid in %s did not match running relay " pid_file;
          exit 5
        )
    )

  let status () =
    Cohttp_lwt_unix.Client.get status_server >>= fun (_, body) ->
    Cohttp_lwt_body.to_string body >|= Yojson.Basic.from_string

end
