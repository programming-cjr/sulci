(*                                                                          *)
(* (c) 2004, 2005 Anastasia Gornostaeva. <ermine@ermine.pp.ru>              *)
(*                                                                          *)

open Pcre
open Common

exception DictError of string

let dictd_server = 
   try trim (Xml.get_cdata Config.config ~path:["plugins"; "dict"; "server"])
   with _ -> "localhost"

let dictd_port = 
   try int_of_string 
      (trim (Xml.get_attr_s Config.config ~path:["plugins"; "dict"; "server"] 
		"port"))
   with _ -> 2628

let connect server port =
   let inet_addr =
      try Unix.inet_addr_of_string server with Failure("inet_addr_of_string") ->
         (Unix.gethostbyname server).Unix.h_addr_list.(0) in
   let sock_addr = Unix.ADDR_INET (inet_addr, port) in
      try
	 let pair = Unix.open_connection sock_addr in
	    Printf.printf "%s:%d connected\n" server port;
	    pair
      with 
	 | Unix.Unix_error ((Unix.EINTR|Unix.EAGAIN), "connect", _) ->
	      let rec cycle () = 
		 Printf.printf "attempting to connect [%s][%d]\n" server port;
		 try 
		    let pair = Unix.open_connection sock_addr in
		       Printf.printf "again: %s:%d\n" server port;
		       pair
		 with 
		    | Unix.Unix_error ((Unix.EINTR|Unix.EAGAIN), "connect",_) ->
			 cycle ()
		    | _ ->
			 raise (DictError "unable to connect")
	      in
		 cycle ()
	 | _ ->
	      raise (DictError "unable to connect")
		   
exception NoStatus

let status = regexp "([0-9][0-9][0-9]) (.*)"

let get_status in_dict =
   let line = input_line in_dict in
   try
      let r = Pcre.exec ~rex:status line in
	 Pcre.get_substring r 1, Pcre.get_substring r 2
   with Not_found ->
      raise 
	 (DictError "Hmm.. It seems i was connectod to inproper dictd server")

let read_text in_dict =
   let rec cycle acc =
      let line = input_line in_dict in
	 if line = ".\r" then
	    acc
	 else
	    cycle (acc ^ line ^ "\n")
   in
      cycle ""

let cmdlist = ["-list"]

let process_cmd_dict cmd =
   if List.mem cmd cmdlist then
      let in_dict, out_dict = connect dictd_server dictd_port in
      let reply = 
	 (match get_status in_dict with
	     | "220", _ ->
		  (match cmd with
		      | "-list" ->
			   output_string out_dict "SHOW DB\r\n";
		      | _ -> raise (DictError "unknown command")
		  );
		  flush out_dict;
		  (match get_status in_dict with
		      | "110", rsp ->
			   let piece = read_text in_dict in
			   let _ = get_status in_dict in
			      rsp ^ "\n" ^ piece
		      | "554", rsp ->
			   rsp
		      | code, rsp ->
			   raise (DictError ("Unknown status code: " ^ 
						  code ^ " " ^ rsp))
		  );
	     | _ -> 
		  raise (DictError "Cannot work!")
	 ) in
	 close_in in_dict;
	 reply
   else
      "Unknown command"

let process_dict db word lang =
   let in_dict, out_dict = connect dictd_server dictd_port in
   let reply = match get_status in_dict with
      | "220", _ ->
	   output_string out_dict 
	       (Printf.sprintf "DEFINE %s %s\r\n" db word);
	   flush out_dict;
	   (match get_status in_dict with
	       | "550", err -> 
		    Lang.get_msg ~lang "plugin_dict_db_not_found" []
	       | "552", err -> 
		    Lang.get_msg ~lang "plugin_dict_word_not_found" []
	       | "150", rsp -> 
		    let rec cycle acc =
		       match get_status in_dict with
			  | "151", text ->
			       let piece = read_text in_dict in
				  cycle (acc ^ "\n" ^ text ^ "\n" ^ piece)
			  | "250", _ ->
			       acc
			  | code, txt -> 
			       raise (DictError ("unknown dict status " ^ 
						 code ^ " " ^ txt))
		    in
		       cycle rsp;
	       | "151", rsp ->
		    let piece = read_text in_dict in
		    let _ = get_status in_dict in
		       rsp ^ "\n" ^ piece
	       | code, rsp ->
		    raise (DictError ("Unknown status code " ^
				      code ^ " " ^ rsp))
	   )
      | _ -> "Cannot work!"
   in
      close_in in_dict;
      reply

let rex1 = Pcre.regexp ~iflags:(cflags [`UTF8]) "([^\\s]+)[\\s]*$"
let rex2 = Pcre.regexp "(!|\\*|[a-z]+)\\s+([a-z]+)"

let dict text event xml out =
   if text = "" then
      out (make_msg xml
	      (Lang.get_msg ~xml "plugin_dict_invalid_syntax" []))
   else
      if String.get text 0 = '-' then
	 let proc () =
	    let response = try
	       process_cmd_dict text
	    with DictError error -> error
	    in 
	       out (make_msg xml (Xml.crypt response))
	 in
	    ignore (Thread.create proc ())
      else 
	 try 
	    let r = Pcre.exec ~rex:rex2 text in
	    let db = Pcre.get_substring r 1 in
	    let word = Pcre.get_substring r 2 in
	    let proc () =
	       let response = try
		  let lang = Lang.get_lang xml in
		     process_dict db word lang
	       with (DictError error) -> error
	       in
		  out (make_msg xml (Xml.crypt response))
	    in
	       ignore (Thread.create proc ())
	 with Not_found ->
	    try
	       let r = Pcre.exec ~rex:rex1 text in
	       let word = Pcre.get_substring r 1 in
	       let proc () =
		  let response = try
		     let lang = Lang.get_lang xml in
			process_dict "*" word lang
		  with (DictError error) -> error
		  in
		     out (make_msg xml (Xml.crypt response))
	       in
		  ignore (Thread.create proc ())
	    with Not_found ->
	       out (make_msg xml 
		       (Lang.get_msg ~xml "plugin_dict_invalid_syntax" []))

let _ =
   Hooks.register_handle (Hooks.Command ("dict", dict))
