open Common
open Dbm

let tlds = opendbm "tlds" [Dbm_rdonly] 0o666

let tld text xml out =
   if text = "" then
      out (make_msg xml "какой домен?")
   else
      if text = "*" then
	 out (make_msg xml "http://www.iana.org/cctld/cctld-whois.htm")
      else
	 let tld = if text.[0] = '.' then string_after text 1 else text in
	    out (make_msg xml (try Dbm.find tlds tld with Not_found -> 
				  "неизвестный домен"))

let _ =
   Hooks.register_handle (Hooks.Command ("tld", tld))