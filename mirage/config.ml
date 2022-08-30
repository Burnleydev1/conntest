open Mirage

let name =
  let long_name = "name" in
  let doc =
    Key.Arg.info
      ~docv:"<STRING>"
      ~doc:"The name of the unikernel, used to show successful connections \
            in other instances of conntest."
      [ long_name ]
  in
  Key.(create long_name Arg.(required ~stage:`Run string doc))

let string_list_conv ~sep =
  let serialize = 
    let serialize_list x = Fmt.Dump.list x in
    serialize_list (fun fmt v -> Fmt.pf fmt "%S" v)
  in
  let conv = Cmdliner.Arg.(list ~sep string) in
  let runtime_conv = Fmt.str "(Cmdliner.Arg.(list ~sep:'%c' string))" sep in
  Key.Arg.conv ~conv ~runtime_conv ~serialize

let listens =
  let long_name = "listen" in
  let info_v =
    Key.Arg.info
      ~docv:"<PROTO>:<PORT>"
      ~doc:"Which protocol and port to listen to respectively, separated \
            by ':'. E.g. tcp:1234"
      [ long_name ]
  in
  Key.(create long_name
      Arg.(opt_all ~stage:`Run (string_list_conv ~sep:':') info_v)
  )

let connections =
  let long_name = "connect" in
  let docv = "<URI>" in
  let doc = Printf.sprintf
      "Which other conntest-instance URIs to connect to. Query \
       parameters are used to pass extra options, which includes \
       'monitor-bandwidth'. Supported protocols are 'tcp' and 'udp'. \
       Currently only IP's are supported in URIs hostname section. \
       E.g. tcp://1.2.3.4:1234?monitor-bandwidth"
  in
  let info_v = Key.Arg.info ~doc ~docv [ long_name ] in
  Key.(create long_name Arg.(opt_all ~stage:`Run string info_v))

let keys = [
  key name;
  key listens;
  key connections;
]

let packages = [
  package "conntest" ~pin:"git+https://github.com/rand00/conntest.git";
  (*< add commit to string? e.g. #3c85fff2aba1bbf0d0e7f05427d7e41f9b7a7cc3*)
  package "uri";
  package "notty" ~pin:"git+https://github.com/rand00/notty.git#414_w_mirage"
    ~sublibs:["mirage"]
  (*~pin:"git+https://github.com/kit-ty-kate/notty.git#414"*)
]

(* module Notty = struct
 *   module F = Functoria 
 * 
 *   type notty = NOTTY
 *   let typ = F.Type.v NOTTY
 *   (\*>goto pass packages_v + connect?*\)
 *   let impl = F.impl "Notty_mirage.Terminal_link_of_console" @@ console
 * 
 *   (\*goto how to make 2 functor applications in a row?*\)
 * end *)

let main = main ~keys ~packages "Unikernel.Main"
    (console @-> stackv4v6 @-> time @-> job)

let stack = generic_stackv4v6 default_network
let console = default_console
let time = default_time

let () = register "conntest" [ main $ console $ stack $ time ]
