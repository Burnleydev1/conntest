open Lwt.Infix
open Lwt_result.Syntax

module Output = Output

let (let*) = Result.bind 
let (let+) x f = Result.map f x 

module type Protocol_S = sig 

  module Listen : sig 
    val start : name:string -> port:int -> timeout:int -> unit
  end

  module Connect : sig
    val start :
      name:string ->
      port:int ->
      ip:Ipaddr.t ->
      monitor_bandwidth:< enabled : bool; packet_size : int; .. > ->
      timeout:int ->
      'a Lwt.t
  end

end


module type S = sig

  module Tcp : Protocol_S
  module Udp : Protocol_S

end

module type STACK_V = sig
  type t 
  val stack : t
end

module Make
    (Time : Mirage_time.S)
    (S : Tcpip.Stack.V4V6)
    (Sv : STACK_V with type t = S.t)
    (O : Output.S)
= struct

  let error_to_msg pp v =
    v >>= function
    | Ok v -> Lwt_result.return v
    | Error err ->
      let msg = Fmt.str "%a" pp err in
      Lwt_result.fail @@ `Msg msg

  module Tcp_flow = struct
    include S.TCP

    type t = S.TCP.flow

    let tcp_stack = S.tcp Sv.stack

    let listen ~port callback =
      S.TCP.listen tcp_stack ~port callback

    let unlisten ~port =
      S.TCP.unlisten tcp_stack ~port 

    let create_connection ~id:_ dst =
      S.TCP.create_connection tcp_stack dst
      |> error_to_msg S.TCP.pp_error

    let read flow = S.TCP.read flow |> error_to_msg S.TCP.pp_error

    let writev flow data =
      S.TCP.writev flow data |> error_to_msg S.TCP.pp_write_error

  end
  
  module Tcp = Protocol.Make(Time)(Tcp_flow)(O)(struct
    let subproto = `Tcp
  end)

  module Ring = struct

    type 'a t = {
      ring : 'a option array;
      index : int;
    }

    let make n : 'a t =
      let ring = Array.make n None in
      let index = 0 in
      { ring; index }

    let length r = Array.length r.ring

    let push field r =
      let index = succ r.index mod Array.length r.ring in
      let forgotten_field = r.ring.(index) in
      r.ring.(index) <- Some field;
      { r with index }, forgotten_field

    let wrap_reverse_i r i =
      assert (i >= 0);
      let len = Array.length r.ring in
      if i >= len then None else
        let ci = r.index in
        let i_wrapped = if i <= ci then ci - i else len + (ci - i) in
        Some i_wrapped
    
    let get_previous r i =
      Option.bind (wrap_reverse_i r i) (fun i -> r.ring.(i))
    
    let get_latest r = get_previous r 0

    let map f r =
      let f = function
        | None -> None
        | Some v -> Some (f v)
      in
      { r with ring = Array.map f r.ring }

    let fold_left f acc r =
      let f acc = function
        | None -> acc
        | Some v -> f acc v
      in
      let len = Array.length r.ring in
      let acc = ref acc in
      for i = pred len downto 0 do
        let i = wrap_reverse_i r i |> Option.get in
        acc := f !acc r.ring.(i);
      done;
      !acc

  end

  module Udp_flow = struct
    (* include S.UDP *)

    (*> Note: must not be bigger than some internal OS buffer for UDP packets
      being received
      * goto research this semantics
        * if there exist no such buffer, then an ack should be sent after each packet
        * note that this layer of the protocol already consumes packets faster than upper
          layer protocol
    *)
    
    let ack_receiver_bound = 4
    let ack_sender_bound = ack_receiver_bound + 4

    (*> TESTING different values*)
    (* let ack_receiver_bound = 1 *)
    (* let ack_sender_bound = ack_receiver_bound *)
    (* let ack_receiver_bound = 10 *)
    (* let ack_sender_bound = ack_receiver_bound + 4 *)
    
    let ring_size = ack_sender_bound
    (*> Note: just set this to some value where upper and lower protocol can run at slightly
      different speeds, to allow some packets to take longer to consumer than others in upper
      protocol
    *)
    let bounded_stream_size = ring_size * 2

    type ring_field = {
      data : Cstruct.t option; (*None => packet is late*)
      packet_index : int;
      (*< goto maybe this field could be avoided, as packet bears this info,
        .. and it's calculated from prev packet otherwise*)
      meta : Packet.Header.meta;
    }

    (*> Note: a stream is used to avoid blocking ringbuffer-handler*)
    type 'a bounded_stream = 'a Lwt_stream.t * 'a Lwt_stream.bounded_push
    type 'a stream = 'a Lwt_stream.t * ('a option -> unit)

    type err = [ `Msg of string ]
    
    (*> goto maybe; [sink, source, feeder] could be a single abstraction*)
    type t = {
      is_client : bool;
      sink : ring_field Lwt_mvar.t;
      source : (Cstruct.t Mirage_flow.or_eof, err) result bounded_stream;
      feeder : unit Lwt.t;
      port : int;
      pier : Ipaddr.t;
      pier_port : int;
      conn_id : string;
      (*<goto maybe; this could be avoided, as Conn_map has it as key*)
      backpressure : unit stream;
    }

    let udp_stack = S.udp Sv.stack

    module Conn_map = Map.Make(String)

    (*> Warning: but don't know why you would run two instances of protocol*)
    let conn_map = ref (Conn_map.empty)

    type writev_ctx = {
      dst : Ipaddr.t;
      dst_port : int;
      src_port : int;
    }
    
    let writev' ~ctx datas =
      let { src_port; dst; dst_port } = ctx in
      (*> Note: it's important that all cstructs are written at once for ordering*)
      let data = Cstruct.concat datas in
      S.UDP.write ~src_port ~dst ~dst_port udp_stack data
      |> error_to_msg S.UDP.pp_error

    let rec fill_backpressure backpressure = function
      | 0 -> Lwt.return_unit
      | n -> 
        (snd backpressure) @@ Some ();
        fill_backpressure backpressure @@ pred n

    let feed_source ~conn_id ~writev_ctx ~sink ~source ~backpressure =
      let is_forgotten_lost forgotten_opt =
        forgotten_opt |> Option.fold ~none:0 ~some:(fun forgotten ->
          if Option.is_none forgotten.data then 1 else 0
        )
      in
      let push_until_packet ~ring ~ring_field ~packet_index_diff =
        let final_packet_index = ring_field.packet_index in
        let rec aux ~lost_packets ~ring = function
          | 0 ->
            let ring, forgotten = ring |> Ring.push ring_field in
            let lost_packets =
              lost_packets + (is_forgotten_lost forgotten)
            in
            ring, lost_packets
          | packet_index_diff ->
            let ring_field_not_received =
              let packet_index = final_packet_index - packet_index_diff in
              { packet_index; data = None; meta = `Normal }
            in
            let ring, forgotten = ring |> Ring.push ring_field_not_received in
            let lost_packets =
              lost_packets + (is_forgotten_lost forgotten)
            in
            aux ~lost_packets ~ring @@ pred packet_index_diff
        in
        aux ~lost_packets:0 ~ring packet_index_diff
      in
      let send_ack () =
        let data =
          let header = Packet.T.{
            index = -1;
            connection_id = conn_id;
            meta = `Ack;
          } in
          Packet.to_cstructs ~header ~data:Cstruct.empty
        in
        writev' ~ctx:writev_ctx data
      in
      let rec loop_packets
          ~received_packets
          ~last_feeded_packet_index
          ~delayed_packets
          ~lost_packets
          ring
        =
        Logs.err (fun m -> m "DEBUG: before Lwt_mvar.take sink");
        Lwt_mvar.take sink >>= fun ring_field ->
        Logs.err (fun m -> m "DEBUG: after Lwt_mvar.take sink");
        begin match ring_field.meta with
          | `Ack ->
            Logs.err (fun m -> m "DEBUG: feed_source: received `Ack");
            Lwt_stream.junk_old (fst backpressure) >>= fun _ ->
            fill_backpressure backpressure ack_sender_bound >>= fun () ->
            loop_packets
              ~received_packets
              ~last_feeded_packet_index
              ~delayed_packets
              ~lost_packets
              ring
          | `Resend_ack -> failwith "todo"
          (*goto howto;
            * can't
              * recurse, as next resend-ack happens after receiving next packet
              * solely call send_ack, as error needs to propagate to 'read' user
                * @idea;
                  * send_ack here
                  * pass result to recursive call
                  * use passed result on next read
          *)
          | `Normal ->
            let received_packets = succ received_packets in
            begin (*Sending an `Ack *)
              if received_packets mod ack_receiver_bound = 0 then (
                Logs.err (fun m -> m "DEBUG: feed_source: sending `Ack");
                send_ack ()
              ) else Lwt.return (Ok ())
            end >>= fun send_ack_result ->
            Logs.err (fun m -> m "DEBUG: feed_source: UDP pkt recvd");
            let expected_packet_index =
              match Ring.get_latest ring with
              | None -> 0
              | Some v -> succ v.packet_index
            in
            let packet_index_diff =
              ring_field.packet_index - expected_packet_index
            in
            let ring, delayed_packets, lost_packets =
              if packet_index_diff < 0 then (
                (*> Note: this is just easier than calculating index for 'set'
                   .. and ring shouldn't be long
                *)
                Logs.err (fun m -> m "DEBUG: feed_source: packet_index_diff < 0");
                let did_set = ref false in
                let ring = ring |> Ring.map (fun ring_field' ->
                  if ring_field'.packet_index = ring_field.packet_index then (
                    did_set := true;
                    ring_field
                  ) else
                    ring_field'
                )
                in
                (*> Note: a packet can be delayed beyond the length of ring, hence 0 = lost*)
                let delayed_packets = delayed_packets - (if !did_set then 1 else 0) in
                ring, delayed_packets, lost_packets
                (*< goto here out-of-order also need to be tracked*)
              ) else ((*if packet_index_diff >= 0*)
                if packet_index_diff > 0 then 
                  Logs.err (fun m -> m "DEBUG: feed_source: packet_index_diff > 0 (%d)"
                      packet_index_diff
                  );
                let ring, lost_packets_now =
                  push_until_packet ~ring ~ring_field ~packet_index_diff in
                let delayed_packets = delayed_packets + packet_index_diff in
                ring, delayed_packets, lost_packets + lost_packets_now
                (*< goto request lost packet to be re-sent? idea is to do this via upper
                    layer protocol if needed
                *)
              )
            in
            ring |> Ring.fold_left (fun acc ring_field' ->
              acc >>= fun (last_feeded_packet_index, seen_empty_data) ->
              let seen_empty_data = seen_empty_data || ring_field'.data = None in
              let packet_index_is_newer =
                ring_field'.packet_index > last_feeded_packet_index
              in
              if packet_index_is_newer && not seen_empty_data then
                (*> Note: The user receives errors from 'ack'-writing on 'read'*)
                let data =
                  send_ack_result |> Result.map (fun () -> 
                    `Data (Option.get ring_field'.data)
                  )
                in
                Logs.err (fun m -> m "DEBUG: feed_source: pushing packet from RING (bounded-stream elements = %d)"
                    ((snd source)#count)
                );
                (snd source)#push data >|= fun () ->
                let last_feeded_packet_index = ring_field'.packet_index in
                last_feeded_packet_index, seen_empty_data
              else
                Lwt.return (last_feeded_packet_index, seen_empty_data)
            ) (Lwt.return (last_feeded_packet_index, false))
            >>= fun (last_feeded_packet_index, _) ->
            loop_packets
              ~received_packets
              ~last_feeded_packet_index
              ~delayed_packets
              ~lost_packets
              ring
        end
      in
      loop_packets
        ~received_packets:0
        ~last_feeded_packet_index:(-1)
        ~delayed_packets:0
        ~lost_packets:0
        (Ring.make ring_size)
    
    let listen ~port user_callback =
      let callback ~src ~dst ~src_port data =
        (*> gomaybe; as we do this, and let upper layer protocol reparse
          .. then this parsing could be made to always happen in this layer,
             .. and data could get sent as Packet.t to upper layer
                .. though would bring more complexity to this layer..
        *)
        Logs.err (fun m -> m "DEBUG: UDP CALLBACK!");
        match Packet.Tcp.init ~ignore_data:true data with
        | Ok (`Done (packet, _rest)) ->
          let conn_id = packet.Packet.T.header.connection_id in
          begin match Conn_map.find_opt conn_id !conn_map with
          | None -> 
            Logs.err (fun m -> m "DEBUG: listen-callback: rcvd pkt(i=%d) and creating connection"
                packet.Packet.T.header.index
            );
            let ring_field =
              let data = Some data in
              let packet_index = packet.Packet.T.header.index in
              let meta = packet.Packet.T.header.meta in
              { data; packet_index; meta }
            in
            let sink = Lwt_mvar.create ring_field in
            let source = Lwt_stream.create_bounded bounded_stream_size in
            let writev_ctx = { dst = src; dst_port = src_port; src_port = port } in
            let backpressure = Lwt_stream.create () in
            fill_backpressure backpressure ack_sender_bound >>= fun () ->
            let feeder =
              feed_source
                ~conn_id
                ~writev_ctx
                ~sink
                ~source
                ~backpressure
            in
            let flow = {
              is_client = false;
              sink;
              source;
              port;
              pier = src;
              pier_port = src_port;
              conn_id;
              feeder;
              backpressure;
            } in
            let conn_map' = Conn_map.add conn_id flow !conn_map in
            conn_map := conn_map';
            Lwt.async (fun () -> user_callback flow);
            Lwt.return_unit
          | Some flow ->
            Logs.err (fun m -> m "DEBUG: listen-callback: rcvd pkt(i=%d) and found connection"
                packet.Packet.T.header.index
            );
            let ring_field =
              let data = Some data in
              let packet_index = packet.Packet.T.header.index in
              let meta = packet.Packet.T.header.meta in
              { data; packet_index; meta }
            in
            Lwt_mvar.put flow.sink ring_field
          end
        | Ok (`Unfinished _) ->
          failwith "Udp_flow: `Unfinished is unsupported for UDP"
        | Error (`Msg err) ->
          failwith ("Udp_flow: Error: "^err) 
      in
      S.UDP.listen udp_stack ~port callback

    let unlisten ~port =
      S.UDP.unlisten udp_stack ~port 

    module Udp_port = struct 
    
      module PSet = Set.Make(Int)

      let used_ports = ref PSet.empty

      (*goto depends on Random.init done somewhere*)
      let rec allocate () =
        let port = 10_000 + Random.int 50_000 in
        if PSet.mem port !used_ports then
          allocate ()
        else
          let used_ports' = PSet.add port !used_ports in
          used_ports := used_ports';
          port

      let free port =
        let used_ports' = PSet.remove port !used_ports in
        used_ports := used_ports'
      
    end

    let create_connection ~id (pier, pier_port) =
      let conn_id = id in
      let sink = Lwt_mvar.create_empty () in
      let source = Lwt_stream.create_bounded bounded_stream_size in
      (*> goto handle that user shouldn't create a server-listening port that
        can be allocated here as well*)
      let port = Udp_port.allocate () in
      let writev_ctx = { dst = pier; dst_port = pier_port; src_port = port } in
      let backpressure = Lwt_stream.create () in
      fill_backpressure backpressure ack_sender_bound >>= fun () ->
      let feeder =
        feed_source
          ~conn_id
          ~writev_ctx
          ~sink
          ~source
          ~backpressure
      in
      let flow = {
        is_client = true;
        sink;
        source;
        port;
        pier;
        pier_port;
        conn_id;
        feeder;
        backpressure;
      } in
      let conn_map' = Conn_map.add id flow !conn_map in
      conn_map := conn_map';
      listen ~port (fun _flow -> Lwt.return_unit);
      Lwt_result.return flow

    let read flow =
      Lwt_stream.next (fst flow.source) >|= function
      | Ok _ as ok -> ok
      | Error (`Msg _ as msg) -> Error msg
    (*< Note: Opened polymorphic variant msg-type*)

    let writev flow datas =
      (*> Note: it's important that all cstructs are written at once for ordering*)
      let data = Cstruct.concat datas in
      let src_port = flow.port in
      let dst, dst_port = flow.pier, flow.pier_port in
      (*< spec:
        * listen-case: flow is only given to callback on recv first packet
        * connect-case: flow already has dst + dst_port
      *)
      let backpressure, _ = flow.backpressure in
      (*> goto should also send `Expecting_ack within some timeout
        .. and this expecting-ack thread is cancelled if next backpressure
           becomes available*)
      let backpressure_t = Lwt_stream.next backpressure in
      if Lwt.state backpressure_t = Sleep then
        Logs.err (fun m -> m "DEBUG: writev: backpressure!");
      backpressure_t >>= fun () ->
      (*> goto maybe; this ttl didn't fix anything, so maybe set to default*)
      Logs.err (fun m -> m "DEBUG: writev: writing!");
      begin
        S.UDP.write ~ttl:100 ~src_port ~dst ~dst_port udp_stack data
        |> error_to_msg S.UDP.pp_error
      end >|= fun r ->
      Logs.err (fun m -> m "DEBUG: writev: wrote!");
      r

    let dst flow = flow.pier, flow.pier_port

    let close flow =
      if flow.is_client then unlisten ~port:flow.port;
      Logs.err (fun m -> m "DEBUG: close: Cancelling feeder");
      Lwt.cancel flow.feeder;
      Logs.err (fun m -> m "DEBUG: close: Done cancelling feeder");
      let conn_map' = Conn_map.remove flow.conn_id !conn_map in
      conn_map := conn_map';
      if flow.is_client then Udp_port.free flow.port;
      Logs.err (fun m -> m "DEBUG: close: returning unit");
      Lwt.return_unit
    
  end
  
  module Udp = Protocol.Make(Time)(Udp_flow)(O)(struct
    let subproto = `Udp
  end)

end
