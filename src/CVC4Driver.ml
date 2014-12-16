(* This file is part of the Kind 2 model checker.

   Copyright (c) 2014 by the Board of Trustees of the University of Iowa

   Licensed under the Apache License, Version 2.0 (the "License"); you
   may not use this file except in compliance with the License.  You
   may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0 

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied. See the License for the specific language governing
   permissions and limitations under the License. 

*)

include GenericSMTLIBDriver

(* Configuration for CVC4 *)
let cmd_line () = 

  (* Path and name of CVC4 executable *)
  let cvc4_bin = Flags.cvc4_bin () in

  if Flags.pdr_tighten_to_unsat_core () then 

    (* Use unsat core option *)
    [| cvc4_bin; 
       "--lang"; "smt2";
       "--rewrite-divk";
       "--tear-down-incremental";
       "--produce-unsat-cores" |]

  else

    (* Omit unsat core option for version older than 1.5 *)
    [| cvc4_bin; 
       "--lang"; "smt2";
       "--rewrite-divk";
       "--incremental" |]


let check_sat_limited_cmd _ = 
  failwith "check-sat with timeout not implemented for CVC4"


let check_sat_assuming_cmd () =
  failwith "No check-sat-assuming command for CVC4"


let check_sat_assuming_supported () = false

