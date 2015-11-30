(* This file is part of the Kind 2 model checker.

   Copyright (c) 2015 by the Board of Trustees of the University of Iowa

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

open Lib

(* Abbreviations *)
module I = LustreIdent
module D = LustreIndex
module E = LustreExpr
module N = LustreNode
module F = LustreFunction
module G = LustreGlobals
module C = LustreContext

module A = Analysis
module S = SubSystem

module SVS = StateVar.StateVarSet 
module SVM = StateVar.StateVarMap 


(********************)
(* Helper functions *)
(********************)

(* Returns [true] if the variable is an array index variable *)
let is_index_var v =
  Var.is_free_var v &&
  let s = Var.hstring_of_free_var v |> HString.string_of_hstring in
  try
    Scanf.sscanf s ("__index_%s")
      (fun _ -> true)
  with Scanf.Scan_failure _ -> false


(* Returns the offset of an index in an array access, e.g. k-1 in A[k-1] has
   offset -1. *)
let offset_of_index expr =
  let t = E.unsafe_term_of_expr expr in
  let tv =
    match Term.vars_of_term t
          |> Var.VarSet.elements
          |> List.filter is_index_var with
    | [v] -> Term.mk_var v
    | _ ->
      Var.mk_fresh_var Type.t_int |> Term.mk_var
  in
  let offset = Term.mk_minus [t; tv] in
  Simplify.simplify_term [] offset


(* Take array indexes on an apparent cycle and checks if the sum of their
   offests is negative, i.e. for A[k-1], B[i], C[j-2] this checks that
   k-1-k + i-i + j-2-j < 0 *)
let sum_indexes_negative indexes =
  let offsets = List.map offset_of_index indexes in
  let neg_offset_test =
    Term.mk_lt [Term.mk_plus offsets; Term.mk_num_of_int 0] in
  let neg_offset_val = Simplify.simplify_term [] neg_offset_test in
  Term.equal neg_offset_val Term.t_true


(* Just sum the offsets (terms) and checks with a cheap operation if they can
   be deemed negative right away. *)
let sum_offsets_negative offsets =
  let neg_offset_test =
    Term.mk_lt [Term.mk_plus offsets; Term.mk_num_of_int 0] in
  let neg_offset_val = Simplify.simplify_term [] neg_offset_test in
  Term.equal neg_offset_val Term.t_true


(* For variable v and parents [a,b,c,v,d,v,v,e,f], returns
   [[a,b,c,v],[a,b,c,d,v],[a,b,c,d,v]] *)
let rec gather_offsets_on_cycles state_var parents =
  let rec gather_up_to big_acc small_acc sv parents =
    match parents with
    | ((sv', Some off) as x) :: r when StateVar.equal_state_vars sv' sv ->
      let big_acc = List.rev (x :: small_acc) :: big_acc in
      gather_up_to big_acc [] sv (List.rev_append small_acc r)

    | (sv', None) :: r when StateVar.equal_state_vars sv' sv ->
      raise Exit

    | ((_, Some off) as x) :: r -> gather_up_to big_acc (x :: small_acc) sv r
    | _ :: r -> gather_up_to big_acc small_acc sv r
    | [] -> big_acc
  in
  gather_up_to [] [] state_var parents
  |> List.map (List.map (function | (sv, Some off) -> off | _ -> assert false))


(* Checks if a variable contains a cycle in its dependencies. For apparent
   cycles between arrays, this checks that all apparent cycles have a sum of
   indexes offsets negative. This ensures that arrays defined this way are well
   founded. *)
let has_cycle_path state_var path =
  try
    List.exists (fun offsets_cycle ->
      not (sum_offsets_negative offsets_cycle)
      ) (gather_offsets_on_cycles state_var path)
  with Exit -> true

let has_cycle state_var parents =
  try Some (List.find (has_cycle_path state_var) parents)
  with Not_found -> None


let print_ind fmt = function
  | None -> ()
  | Some off -> Format.fprintf fmt "[%a]" Term.pp_print_term off


(* Return a chain of variable names and node names that describe the
   cycle, in reverse order *)
let rec describe_cycle node accum = function

  | (state_var, ind) :: tl ->

    (* Output state variable if visible, or node call *)
    (match N.get_state_var_source node state_var with

     (* Output state variable if visible *)
     | N.Input | N.Output | N.Local | N.Ghost -> 

       describe_cycle node
         ((Format.asprintf "%a" (E.pp_print_lustre_var false) state_var) :: 
          accum)
         tl

     (* Skip oracles *)
     | N.Oracle -> describe_cycle node accum tl

     (* State variable from abstraction *)
     | exception Not_found -> 

       try 
         (* Find node call with state variable as output *)
         let { N.call_node_name } =
           List.find
             (fun { N.call_node_name; N.call_outputs } -> 
                D.exists (fun _ sv -> StateVar.equal_state_vars state_var sv)
                  call_outputs)
             node.N.calls 
         in

         (* Output name of called node *)
         describe_cycle node
           ((Format.asprintf "<call to %a>"
               (I.pp_print_ident false) call_node_name)
            :: accum)
           tl

       (* Skip abstracted state variable *)
       with Not_found -> describe_cycle node accum tl)

  (* Return in reverse order at end of cycle *)
  | [] -> accum


(* Checks if the state variable appears in some accumulator [accum] or if there
   exists a cycle, then checks that this same variable is also on the cycle. *)
let break_cycle accum parents state_var sv inds =
  List.exists (fun (sv', inds') -> StateVar.equal_state_vars sv sv') accum
  ||
  List.exists (fun path ->
      List.exists (fun (sv', _) -> StateVar.equal_state_vars state_var sv') path
      && List.exists (fun (sv', _) -> StateVar.equal_state_vars sv sv') path
    ) parents


(* Add reverse dependency to the parents of a given state variable. We don't
   bother negating the offsets so we can do the same test for children and
   parents (< 0). *)
let add_dep_to_parents sv indgrps parents =
  if indgrps = [] then
    if parents = [] then [[sv, None]]
    else List.map (fun path -> (sv, None) :: path) parents
  else
    let offsets_inds = List.map (fun inds ->
        List.map offset_of_index inds
        |> Term.mk_plus |> Simplify.simplify_term []
      ) indgrps in
    List.fold_left (fun acc i ->
        let np =
          if parents = [] then [[sv, Some i]]
          else
            List.map (fun path -> (sv, Some i) :: path) parents in
        List.rev_append np acc
      ) [] offsets_inds


(* Strategy for merging dependencies on indexes of array accesses (we keep them
   all). *)
let merge_deps sv oind1 oind2 = match oind1, oind2 with
  | Some i1, Some i2 -> Some (i1 @ i2)
  | Some i, None | None, Some i -> Some i
  | _ -> None

(* Union of a map of dependecies/index with a set of dependencies *)
let union_noind_set m s =
  let m' = SVS.fold (fun sv -> SVM.add sv []) s SVM.empty in
  SVM.merge merge_deps m' m
  

(* ********************************************************************** *)
(* Dependency order of definitions and cycle detection                    *)
(* ********************************************************************** *)

(* For each state variable return the list of state variables in the current
   instant that are used in its definition, and transitively in their
   definitions, and fail if the definitions contain a cycle. The returned list
   also contains offsets for arrays accesses on which the variable definition
   depends. This allows to find cycles for non weel-founded (mutually)
   recurively defined arrays while allowing correct definitions.

   We don't need to consider assertions and node calls here, since we only need
   the ordering only to sort equations and detect cycles.

   We could find potential cycles when a node does not have an implementation,
   but this is more trouble than it's worth. We need to distinguish between
   strong and weak dependencies. If variable is undefined, it weakly depends on
   all inputs. Then we can find weak dependencies through nodes where an input
   is underspecified. However, we then need to eliminate that cycle by
   backtracking over the children we explored and that's where the troubles
   start. *)
let rec node_state_var_dependencies' init output_input_deps
    ({ N.inputs; N.equations; N.calls; N.function_calls } as node)
    accum = function

  (* Return all calculated dependencies *)
  | [] -> accum

  (* Calculate dependency of variable [state_var], which all
     variables in [parents] depend on *)
  | (state_var, parents) :: tl ->

    (* is there a strong dependency cycle with the state
       variable? *)
    match has_cycle state_var parents with
    | Some path ->
      (* Output variables in circular dependency, drop variables
         that are not visible in the origial source *)
      let str_path = describe_cycle node [] ((state_var, None) :: path) in

      C.fail_no_position 
        (Format.asprintf
           "Circular dependency for %a in %a: @[<hov>%a@]@."
           (E.pp_print_lustre_var false) state_var
           (I.pp_print_ident false) node.N.name
           (pp_print_list Format.pp_print_string " ->@ ") str_path)

    | _ ->

      (* All state variables at the current instant in the equation
         defining the state variable *)
      let children = 

        (* Find equations defining the state variable 

           A state variable can be defined in more than one equation
           if an array is defined pointwise *)
        List.find_all
          (fun ((sv, _), _) -> StateVar.equal_state_vars sv state_var)
          equations

        |> 
        List.fold_left

          (* State variable depends on state variables in equation *)
          (fun accum (((sv, _), expr)) ->
             (* Format.eprintf "Equation: %a@." *)
             (*   (N.pp_print_node_equation false) eq; *)

             let state_vars = 
               if init then E.base_state_vars_of_init_expr expr
               else E.cur_state_vars_of_step_expr expr in

             (* add indexes *)
             SVS.fold (fun sv acc ->
                 let indexes =
                   if init then E.indexes_of_state_vars_in_init sv expr
                   else E.indexes_of_state_vars_in_step sv expr in
                 SVM.merge merge_deps (SVM.singleton sv indexes) acc
               ) state_vars accum

          ) SVM.empty

      in

      (* All state variables at the current instant in the node call
         defining the state variable *)
      let children = 

        (* Find node calls defining the state variable *)
        List.find_all
          (fun { N.call_node_name; N.call_outputs } -> 
             D.exists 
               (fun _ sv -> StateVar.equal_state_vars state_var sv)
               call_outputs)
          calls

        |> List.fold_left
          (fun accum { N.call_node_name; call_inputs; call_oracles;
                       call_outputs; call_defaults; call_clock } ->

            (* Index of state variable in outputs *)
            let output_index = 
              try
                (* Find state variable in outputs and return its index *)
                D.bindings call_outputs 
                |> List.find
                  (fun (_, sv) -> StateVar.equal_state_vars state_var sv)
                |> fst
              (* State variable is an output, has been found before *)
              with Not_found -> assert false 
            in

            (* Get computed dependencies of outputs on inputs for called
               node *)
            let output_input_dep =
              try List.assoc call_node_name output_input_deps
                  |> if init then fst else snd
              with Not_found -> D.empty
            in

            (* Get indexes of inputs the output depends on. All outputs must
               have dependencies computed *)
            (try D.find output_index output_input_dep
             with Not_found -> assert false)

            |> List.fold_left (fun accum i -> 
                (* Get actual input by index, and add as dependency *)
                try SVM.add (D.find i call_inputs) [] accum 
                (* Invalid map *)
                with Not_found -> assert false)
              SVM.empty

            (* Defaults of a condact are children *)
            |> (fun children ->

                (* Only if computing dependencies in the initial state *)
                if init then
                  (* Add state variables at the initial state from the default
                     expressions *)
                  match call_defaults with 
                  | None -> children
                  | Some d -> 
                    D.fold (fun _ default accum -> 
                        E.base_state_vars_of_init_expr default
                        |> union_noind_set accum
                      ) d children

                (* Default expressions are only evaluated at the initial
                   state *)
                else children)

            (* Clock of condact is a child *)
            |> (fun children -> match call_clock with 
                | None -> children
                | Some clk -> SVM.add clk [] children)

            (* Add to set of children from equations *)
            |> SVM.merge merge_deps accum)

          children
      in

      (* All state variables at the current instant in the function call
         defining the state variable *)
      let children = 
        (* Find function calls defining the state variable *)
        List.find_all
          (fun { N.call_function_name; call_outputs } -> 
             D.exists 
               (fun _ sv -> StateVar.equal_state_vars state_var sv)
               call_outputs)
          function_calls

        |> List.fold_left (fun accum { N.call_function_name; call_inputs } -> 

            D.fold (fun _ expr accum ->
                (if init then E.base_state_vars_of_init_expr expr
                 else E.cur_state_vars_of_step_expr expr)
                |> union_noind_set accum
              ) call_inputs accum)
          children
      in

      (* Some variables have had their dependencies calculated
         already *)
      let children_visited, children_not_visited =
        SVM.partition (break_cycle accum parents state_var) children
      in

      (* All children visited? *)
      if SVM.is_empty children_not_visited then 

        (* Dependencies of this variable is set of dependencies of its
           variables *)
        let children =
          SVM.fold (fun sv ind a -> 
              try 
                (* Add child as strong dependency to accumulator *)
                SVM.merge merge_deps a (SVM.singleton sv ind)

                (* Add grandchildren as strong or weak dependencies *)
                |> SVM.merge merge_deps
                  (try List.find 
                         (fun (sv', _) -> StateVar.equal_state_vars sv sv')
                         accum |> snd
                   with Not_found -> SVM.empty)

              with Not_found -> assert false
            ) children_visited SVM.empty
        in

        (* Add variable and its dependencies to accumulator *)
        node_state_var_dependencies' 
          init
          output_input_deps
          node 
          ((state_var, children) :: accum)
          tl

      else

        (* First get dependencies of all dependent variables *)
        node_state_var_dependencies' 
          init
          output_input_deps
          node
          accum
          (SVM.fold (fun sv ind a ->
               (sv, add_dep_to_parents state_var ind parents) :: a
             ) children_not_visited ((state_var, parents) :: tl))


(* Given an association list of state variables to the set of the
   state variables they depend on, return the state variables in
   toplogical order 

   There must be no cyclic dependencies, otherwise this function will
   loop forever. *)
let rec order_state_vars accum seen = function

  (* All variables in the accumulator *)
  | [] -> accum

  (* Skip if state variable is already in the accumulator *)
  | (h, _) :: tl when List.mem h accum -> order_state_vars accum seen tl

  (* State variable and the variables it depends on *)
  | (h, d) :: tl -> 
    

    (* All dependencies of state variables, except themselves, in the
       accumulator? *)
    if SVM.for_all (fun sv _ -> List.mem sv accum) d
    || List.mem h seen

    then

      (* Add state variable to accumulator and continue *)
      order_state_vars (h :: accum) [] tl
      
    else

      (* Push all dependent variables to the top of the stack *)
      let tl' = 
        SVM.fold
          (fun sv _ a ->
             try 
               (* Find dependencies of state variable *)
               (List.find 
                  (fun (sv', _) -> StateVar.equal_state_vars sv sv')
                  tl) :: a
             (* All dependent state variables must be in stack *)
             with Not_found -> assert false)
          d
          ((h, d) :: tl)
      in

      (* Must add dependent state variables to accumulator first *)
      order_state_vars accum (h :: seen) tl'
      
      
(* Compute dependencies of outputs on inputs 

   Return a trie that maps each index of a state variable in the
   outputs to the list of indexes of input state variables the output
   depends on. *)
let output_input_dep_of_dependencies dependencies inputs outputs = 

  (* Map trie of output state variables to trie of indexes *)
  D.mapi

    (fun j output -> 

       (* State variables this state variables depends on *)
       let output_dep = 

         try

           (* Get state variables the state variable depends on *)
           List.find 
             (fun (sv', _) -> StateVar.equal_state_vars output sv')
             dependencies

           |> snd 

         (* All dependencies must have been computed *)
         with Not_found -> assert false

       in

       (* Get indexes of all state variables that are inputs *)
       SVM.fold
         (fun sv _ a -> 

            match 

              (* Find state variable in inputs *)
              D.filter
                (fun _ sv' -> StateVar.equal_state_vars sv sv')
                inputs 
              |> D.keys

            with 

              (* State variable is not an input *)
              | [] -> a

              (* Add index of state variable in input to
                 accumulator *)
              | [i] -> i :: a

              (* State variable occurs in input twice *)
              | _ -> assert false)

         output_dep
         [])

    outputs


(* Order equations of node topologically by their dependencies to have leaf
   equations first, and set the map of outputs to the inputs they depend on *)
let order_equations 
    init
    output_input_deps
    ({ N.inputs; N.outputs; N.equations; N.calls } as node) = 

  (* Compute dependencies for state variables on the left-hand side of
     definitions, that is, in equations and node calls *)
  let state_vars = 
    (* State variables on the left-hand side of equations *)
    List.map (fun ((sv, _), _) -> (sv, [])) equations
    |> D.fold (fun _ sv a -> (sv, []) :: a) outputs
    (* Add state variables capturing outputs of node calls *)
    |> (fun accum -> 
        List.fold_left (fun a { N.call_node_name; N.call_outputs } -> 
            D.fold (fun _ sv a -> (sv, []) :: a) call_outputs a
          ) accum calls)
  in

  (* Compute dependencies of state variable *)
  let dependencies = 
    node_state_var_dependencies' init output_input_deps node [] state_vars
  in

  (* Order state variables by dependencies *)
  let state_vars_ordered = order_state_vars [] [] dependencies in

  (* Order equations by state variables *)
  let equations' = List.fold_left (fun a sv ->
      (* Find equations of state variable and add to accumulator.
         There may be more than one equation per state variable if the state
         variable is an array. *)
        List.fold_left (fun a (((sv', _), _) as e) -> 
            if StateVar.equal_state_vars sv sv' then e :: a else a
          ) a equations
      ) [] state_vars_ordered 
  in 

  (* Dependency of output variables on input variables *)
  let output_input_dep = 
    output_input_dep_of_dependencies dependencies inputs outputs
  in

  equations', output_input_dep

          
(* ********************************************************************** *)
(* Cone of influence slicing                                              *)
(* ********************************************************************** *)


(* Initially empty node for slicing *)
let slice_all_of_node 
    ?(keep_props = true)
    ?(keep_contracts = true)
    { N.name; 
      N.instance;
      N.init_flag;
      N.inputs; 
      N.oracles; 
      N.outputs; 
      N.asserts;
      N.props; 
      N.global_contracts; 
      N.mode_contracts; 
      N.is_main;
      N.state_var_source_map } = 

  (* Copy of the node with the same signature, but without local
     variables, equations, assertions and node calls. Keep signature,
     properties, assertions, contracts and main annotation *)
  { N.name; 
    N.instance;
    N.init_flag;
    N.inputs;
    N.oracles; 
    N.outputs; 
    N.locals = [];
    N.equations = [];
    N.calls = [];
    N.function_calls = [];
    N.asserts;
    N.props = if keep_props then props else [];
    N.global_contracts = if keep_contracts then global_contracts else [];
    N.mode_contracts = if keep_contracts then mode_contracts else [];
    N.is_main;
    N.state_var_source_map = state_var_source_map }


(* Add roots of cone of influence from node call to roots *)
let add_roots_of_node_call 
    roots
    { N.call_clock; 
      N.call_inputs; 
      N.call_oracles; 
      N.call_defaults } =

  (* Add dependencies from defaults as roots *)
  let roots' =
    match call_defaults with
      | None -> roots
      | Some d -> 

        D.fold
          (fun _ e a -> 
             (E.state_vars_of_expr e |> SVS.elements) @ a) 
          d
          roots
  in

  (* Add inputs, oracles and clock as roots *)
  let roots' = 

    (* Need dependecies of inputs to node call *)
    D.values call_inputs @ 

    (* Need dependencies of oracles *)
    call_oracles @ 

    (* Need dependencies of clock if call has one *)
    (match call_clock with
      | None -> roots'
      | Some c -> c :: roots')

  in

  (* Return with new roots added *)
  roots'


(* Add roots of cone of influence from node call to roots *)
let add_roots_of_function_call 
    roots
    { N.call_inputs } =

  (* Add dependecies of input expressions *)
  D.fold
     (fun _ expr accum -> E.state_vars_of_expr expr |> SVS.union accum)
     call_inputs
     (SVS.of_list roots)

  |> SVS.elements

(* Add roots of cone of influence from equation to roots *)
let add_roots_of_equation roots (_, expr) = 
  (E.state_vars_of_expr expr |> SVS.elements) @ roots


(* Return state variables from properties *)
let roots_of_props = List.map (fun (sv, _, _) -> sv)


(* Return state variables from contracts *)
let roots_of_contracts contract = 

  (* State variables in a contract are requirements and ensures *)
  let roots_of_contract { N.contract_reqs; N.contract_enss } = 
    (List.map snd contract_reqs) @ (List.map snd contract_enss)
  in

  (* Combine state variables from global contract and mode
     contracts *)
  List.fold_left 
    (fun a c -> roots_of_contract c @ a)
    []
    contract

(* Add state variables in assertion *)
let add_roots_of_asserts asserts roots = 
  List.fold_left 
    (fun accum expr -> E.state_vars_of_expr expr |> SVS.union accum)
    roots
    asserts

(* Reduce nodes to cone of influence

   The last argument is a stack of quadruples [(roots, leaves, sliced,
   unsliced)]. For each state variable in [roots], all [equations],
   [calls] and [locals] that mention the state variable are to be
   moved from the node [unsliced] to the node [sliced]. If the state
   variable is in [leaves], either the state variables mentioned in
   equations, asserts or node calls are already in [roots], or the
   definitions of the state variable should not be expanded.

   If a state variable in [roots] is defined by a node call, find the
   called node in [nodes], obtain an initial quadruple for the stack
   with [init_slicing_of_node] and push it to the top of the stack so
   that the called node is sliced first. 

   Call this function with *)
let rec slice_nodes
    init_slicing_of_node
    nodes
    functions_in_coi
    functions_not_in_coi
    accum = 

  function 

    (* All nodes are sliced and in the accumulator *)
    | [] -> accum, functions_in_coi

    (* Node is sliced to all equations *)
    | ([], 
       leaves, 
       ({ N.name; 
          N.inputs; 
          N.oracles; 
          N.outputs; 
          N.locals; 
          N.state_var_source_map } as node_sliced), 
       node_unsliced) :: tl -> 
      
      (* If this is the top node, slice away inputs and outputs *)
      let inputs', outputs' = 
        if tl = [] then 
          (

            (* Only keep inputs that have been visited *)
            D.filter
              (fun _ sv -> List.exists (StateVar.equal_state_vars sv) leaves)
              inputs,

            (* Only keep inputs that have been visited *)
            D.filter
              (fun _ sv -> List.exists (StateVar.equal_state_vars sv) leaves)
              outputs)
        else
          inputs, outputs
      in
      
      (* Local variables related by an index have been moved together,
         now discard not visited indexes *)
      let locals' = 
        List.fold_left 
          (fun a l ->
             D.fold
               (fun i sv a -> 
                  if 

                    (* Has state variable been visited ? *)
                    List.exists (StateVar.equal_state_vars sv) leaves 

                  then

                    (* Keep its definition as a local state variable *)
                    D.add i sv a

                  else

                    (* Remvoe definition of not visited state
                       variable *)
                    a)
               l
               D.empty :: a)
          []
          locals 
      in

      (* Replace inputs and outputs in sliced node *)
      let node_sliced = 
        { node_sliced with
            N.inputs = inputs'; 
            N.outputs = outputs';
            N.locals = List.rev locals' }
      in

      (* Continue with next nodes *)
      slice_nodes
        init_slicing_of_node
        nodes
        functions_in_coi
        functions_not_in_coi
        (node_sliced :: accum)
        tl

    (* State variable is a leaf, that is no dependencies have to be
       added, because it has been visited, or should not be expanded *)
    | (state_var :: roots_tl, leaves, node_sliced, node_unsliced) :: tl 
      when List.exists (StateVar.equal_state_vars state_var) leaves -> 

      slice_nodes
        init_slicing_of_node
        nodes
        functions_in_coi
        functions_not_in_coi
        accum
        ((roots_tl, leaves, node_sliced, node_unsliced) :: tl)

    (* State variable is not a leaf, need to add all dependencies *)
    | (state_var :: roots', 
       leaves, 
       ({ N.equations = equations_in_coi;
          N.calls = calls_in_coi;
          N.function_calls = function_calls_in_coi;
          N.locals = locals_in_coi } as node_sliced),
       ({ N.equations = equations_not_in_coi; 
          N.calls = calls_not_in_coi;
          N.function_calls = function_calls_not_in_coi;
          N.locals = locals_not_in_coi } as node_unsliced)) :: tl as l -> 

      try 

        (* State variable is an output of a called node that is not
           already sliced? *)
        let { N.call_node_name } =
          List.find
            (function { N.call_node_name; N.call_outputs } ->

              (* Called node is not already sliced? *)
              (not (N.exists_node_of_name call_node_name accum)

               &&

               (* State variable is an output of the called node? *)
               D.exists
                 (fun _ sv -> StateVar.equal_state_vars state_var sv)
                 call_outputs))
            calls_not_in_coi
        in

        (* Get called node by name *)
        let node = N.node_of_name call_node_name nodes in

        (* Slice called node first, then return to this node

           TODO: Detect cycles in node calls here, but that should not
           be possible with the current format. *)
        slice_nodes
          init_slicing_of_node
          nodes
          functions_in_coi
          functions_not_in_coi
          accum
          (init_slicing_of_node node :: l)

      (* State variable is not defined by a node call *)
      with Not_found -> 

        (* Equations with defintion of variable added, and new roots
           from dependencies of equation *)
        let equations_in_coi', equations_not_in_coi', roots' = 

          List.fold_left 

            (fun
              (equations_in_coi, equations_not_in_coi, roots')
              (((sv, _), expr) as eq) -> 

              (* Equation defines variable? *)
              if StateVar.equal_state_vars state_var sv then

                (* Add equation to sliced node *)
                (eq :: equations_in_coi, 

                 (* Remove equation from unsliced node *)
                 equations_not_in_coi,

                 (* Add variables in equation as roots *)
                 add_roots_of_equation roots' eq)

              else

                (* Do not add equation to sliced node, keep in unsliced
                   node, and no new roots *)
                (equations_in_coi, eq :: equations_not_in_coi, roots')

            )

            (* Modify equations in sliced and unsliced node, and roots *)
            (equations_in_coi, [], roots')

            (* Iterate over all equations in unsliced node *)
            equations_not_in_coi

        in

        (* Node calls with call returning state variable added, and new
           roots from dependencies of node call *)
        let calls_in_coi', calls_not_in_coi', roots' = 

          List.fold_left 

            (fun
              (calls_in_coi, calls_not_in_coi, roots')
              ({ N.call_node_name; 
                 N.call_outputs } as node_call) ->

              if

                (* State variable is an output of the called node? *)
                LustreIndex.exists
                  (fun _ sv -> StateVar.equal_state_vars state_var sv)
                  call_outputs


              then

                (* Add equation to sliced node *)
                (node_call :: calls_in_coi, 

                 (* Remove equation from unsliced node *)
                 calls_not_in_coi,

                 (* Add variables in equation as roots *)
                 add_roots_of_node_call roots' node_call)


              else

                (* Do not add node call to sliced node, keep in unsliced
                   node, and no new roots *)
                (calls_in_coi, node_call :: calls_not_in_coi, roots')

            )

            (* Modify node calls in sliced and unsliced node, and roots *)
            (calls_in_coi, [], roots')

            (* Iterate over all node calls in unsliced node *)
            calls_not_in_coi

        in

        (* Funtion calls with call returning state variable added, and
           new roots from inputs of function call *)
        let 

          function_calls_in_coi', 
          function_calls_not_in_coi', 
          functions_in_coi', 
          functions_not_in_coi', 
          roots' = 

          List.fold_left 

            (fun
              (function_calls_in_coi, 
               function_calls_not_in_coi, 
               functions_in_coi, 
               functions_not_in_coi, 
               roots')
              ({ N.call_function_name; 
                 N.call_outputs } as function_call) ->

              if

                (* State variable is an output of the called function? *)
                LustreIndex.exists
                  (fun _ sv -> StateVar.equal_state_vars state_var sv)
                  call_outputs


              then

                (* Add equation to sliced node *)
                (function_call :: function_calls_in_coi, 

                 (* Remove equation from unsliced node *)
                 function_calls_not_in_coi,

                 (if 
                   
                   (* Called function already in coi? *)
                   List.exists 
                     (function { F.name } -> 
                       LustreIdent.equal name call_function_name)
                     functions_in_coi
                     
                  then 
                    
                    (* Do not add again *)
                    functions_in_coi
                      
                  else
                    
                    try 
                      
                      (* Add called function *)
                      List.find 
                        (function { F.name } -> 
                          LustreIdent.equal name call_function_name)
                        functions_not_in_coi
                        
                      :: functions_in_coi
                      
                    (* Called function must be in that list *)
                    with Not_found -> assert false),
                     
                 (* Filter out called function *)
                 List.filter
                   (function { F.name } -> 
                     LustreIdent.equal name call_function_name |> not)
                   functions_not_in_coi,

                 (* Add variables in equation as roots *)
                 add_roots_of_function_call roots' function_call)


              else

                (* Do not add node call to sliced node, keep in unsliced
                   node, and no new roots *)
                (function_calls_in_coi, 
                 function_call :: function_calls_not_in_coi, 
                 functions_in_coi, 
                 functions_not_in_coi, 
                 roots')

            )

            (* Modify node calls in sliced and unsliced node, and roots *)
            (function_calls_in_coi,
             [], 
             functions_in_coi, 
             functions_not_in_coi, 
             roots')

            (* Iterate over all node calls in unsliced node *)
            function_calls_not_in_coi

        in

        (* Move definitions containing the state variable from the
           unsliced to sliced node

           We move definitions of all local variables related by an
           index together and eliminate the not visited ones at the
           end. If we wanted to move indexed state variables one by one,
           we would need to have a way to find out which local state
           variable trie to insert it into.*)
        let locals_in_coi', locals_not_in_coi' =

          List.fold_left

            (fun (locals_in_coi, locals_not_in_coi) l -> 

               if 

                 (* Local definition contains the state variable? *)
                 (D.exists
                    (fun _ sv -> StateVar.equal_state_vars sv state_var))
                   l

               then

                 (* Add all state variables related by an index to this
                    state variable as local variables, but do not add
                    them as roots *)
                 (l :: locals_in_coi, locals_not_in_coi)

               else

                 (* Do not add local variable to sliced node, keep in
                    unsliced node *)
                 (locals_in_coi, l :: locals_not_in_coi))

            (* Modify local variables in sliced and unsliced node *)
            (locals_in_coi, [])

            (* Iterate over all local variables in unsliced node *)
            locals_not_in_coi

        in

        (* Modify slicecd node *)
        let node_sliced' =
          { node_sliced with
              N.locals = locals_in_coi';
              N.equations = equations_in_coi';
              N.calls = calls_in_coi';
              N.function_calls = function_calls_in_coi' } 
        in

        (* Modify slicecd node *)
        let node_unsliced' =
          { node_unsliced with
              N.equations = equations_not_in_coi';
              N.calls = calls_not_in_coi';
              N.function_calls = function_calls_not_in_coi';
              N.locals = locals_not_in_coi' }
        in

        (* Continue with modified sliced node and roots *)
        slice_nodes
          init_slicing_of_node
          nodes
          functions_in_coi'
          functions_not_in_coi'
          accum
          ((roots', (state_var :: leaves), node_sliced', node_unsliced') :: tl)


(* Slice a node to its implementation, starting from the outputs,
   contracts and properties *)
let root_and_leaves_of_impl  
    is_top
    roots
    ({ N.outputs; 
       N.global_contracts; 
       N.mode_contracts; 
       N.props;
       N.asserts } as node) =

  (* Slice everything from node *)
  let node_sliced = 
    slice_all_of_node
      ~keep_props:true
      ~keep_contracts:true
      node 
  in
  
  (* Slice starting with outputs, contracts and properties *)
  let node_roots = 
    (match roots with 
      
      (* No roots given? *)
      | None -> 

        (* Consider properties and contracts as roots *)
        (roots_of_contracts global_contracts |> SVS.of_list)
        |> SVS.union (roots_of_contracts mode_contracts |> SVS.of_list)
        |> SVS.union (roots_of_props props |> SVS.of_list)
                                          
      (* Use instead of roots from properties and contracts *)
      | Some r -> r)

    |> add_roots_of_asserts asserts

    (* Consider outputs as roots except at the top node *)
    |> SVS.union (if is_top then SVS.empty else D.values outputs |> SVS.of_list) 
    |> SVS.elements
  in

  (* Consider all streams *)
  let node_leaves = [] in

  (node_roots, node_leaves, node_sliced, node)


(* Slice a node to its contracts, starting from contracts, stopping at
   outputs *)
let root_and_leaves_of_contracts
    is_top
    roots
    ({ N.outputs; 
       N.global_contracts; 
       N.mode_contracts; 
       N.props } as node) =

  (* Slice everything from node *)
  let node_sliced = 
    slice_all_of_node 
      ~keep_props:false
      ~keep_contracts:true
      node 
  in
    
  (* Slice starting with contracts *)
  let node_roots = 
    match roots with 
      | None -> 

        roots_of_contracts global_contracts @
        roots_of_contracts mode_contracts 
         
      | Some r -> SVS.elements r
  in

  (* Do not consider anything below outputs *)
  let node_leaves = D.values outputs in

  (node_roots, node_leaves, node_sliced, node)


(* Slice a node to its contracts, starting from contracts, stopping at
   outputs *)
let custom_roots roots node = 

  (* Slice everything from node *)
  let node_sliced = 
    slice_all_of_node 
      ~keep_props:true
      ~keep_contracts:true
      node 
  in
    
  (* Slice starting with given roots *)
  let node_roots = roots in

  (* Consider all streams *)
  let node_leaves = [] in

  (node_roots, node_leaves, node_sliced, node)


(* Return [true] if the node is flagged as abstract in
   [abstraction_map]. Default to [false] if the node is not in the
   map. *)
let node_is_abstract analysis { N.name } = 

  [I.string_of_ident false name]
  |> Analysis.scope_is_abstract analysis


(* Return roots for slicing to contracts or implementation as
   indicated by [abstraction_map]. Use the implementation if a node is
   not in the map. *)
let root_and_leaves_of_abstraction_map 
    is_top
    roots
    abstraction_map
    ({ N.name } as node) = 

  if node_is_abstract abstraction_map node then 

    (* Node is to be abstract *)
    root_and_leaves_of_contracts is_top roots node 

  else

    (* Node is to be concrete *)
    root_and_leaves_of_impl is_top roots node


(* Slice nodes to abstraction or implementation as indicated in
   [abstraction_map] *)
let slice_to_abstraction'
    ({ A.top } as analysis) 
    roots 
    subsystem
    globals = 

  (* Get list of nodes from subsystem in toplogical order with the top
     node at the head of the list *)
  let nodes = 
    S.find_subsystem subsystem top
    |> N.nodes_of_subsystem 
  in 
  
  (* Slice all nodes to either abstraction or implementation *)
  let nodes', functions' = 

    slice_nodes
      (root_and_leaves_of_abstraction_map false roots analysis)
      nodes
      []
      globals.G.functions
      []
      [root_and_leaves_of_abstraction_map true roots analysis (List.hd nodes)]
      
  in
  
  (* Create subsystem from list of nodes *)
  (N.subsystem_of_nodes nodes', { globals with G.functions = functions'})


(* Slice nodes to abstraction or implementation as indicated in
   [abstraction_map] *)
let slice_to_abstraction analysis subsystem globals = 
  slice_to_abstraction' analysis None subsystem globals

  
(* Slice nodes to abstraction or implementation as indicated in
   [abstraction_map] *)
let slice_to_abstraction_and_property analysis term subsystem globals = 

  let roots = Some (Term.state_vars_of_term term) in 
  slice_to_abstraction' analysis roots subsystem globals


  

(* 
   Local Variables:
   compile-command: "make -k -C .."
   indent-tabs-mode: nil
   End: 
*)
  