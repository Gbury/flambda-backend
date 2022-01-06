(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2019 OCamlPro SAS                                    *)
(*   Copyright 2014--2019 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

type t =
  { phantom: bool;
    function_decls : Function_declarations.t;
    closure_elements : Simple.t Var_within_closure.Map.t
  }

let [@ocamlformat "disable"] print ppf
      { function_decls;
        closure_elements;
      } =
  Format.fprintf ppf "@[<hov 1>(%sset_of_closures%s@ \
      @[<hov 1>(function_decls@ %a)@]@ \
      @[<hov 1>(closure_elements@ %a)@]\
      )@]"
    (Flambda_colours.prim_constructive ())
    (Flambda_colours.normal ())
    (Function_declarations.print) function_decls
    (Var_within_closure.Map.print Simple.print) closure_elements

include Container_types.Make (struct
  type nonrec t = t

  let print = print

  let hash _ = Misc.fatal_error "Not yet implemented"

  let compare
      { function_decls = function_decls1; closure_elements = closure_elements1 }
      { function_decls = function_decls2; closure_elements = closure_elements2 }
      =
    let c = Function_declarations.compare function_decls1 function_decls2 in
    if c <> 0
    then c
    else
      Var_within_closure.Map.compare Simple.compare closure_elements1
        closure_elements2

  let equal t1 t2 = compare t1 t2 = 0
end)

let empty =
  { phantom = false;
    function_decls = Function_declarations.empty;
    closure_elements = Var_within_closure.Map.empty
  }

let is_empty { function_decls; closure_elements } =
  Function_declarations.is_empty function_decls
  && Var_within_closure.Map.is_empty closure_elements

let make_phantom t = { t with phantom = true; }

let create function_decls ~closure_elements =
  (* CR mshinwell: Make sure invariant checks are applied here, e.g. that the
     set of closures is indeed closed. *)
  { phantom = false; function_decls; closure_elements }

let function_decls t = t.function_decls

let closure_elements t = t.closure_elements

let has_empty_environment t = Var_within_closure.Map.is_empty t.closure_elements

let environment_doesn't_mention_variables t =
  Var_within_closure.Map.for_all
    (fun _vwc simple -> Simple.is_symbol simple)
    t.closure_elements

let [@ocamlformat "disable"] print ppf
      { function_decls;
        closure_elements;
      } =
  if Var_within_closure.Map.is_empty closure_elements then
    Format.fprintf ppf "@[<hov 1>(%sset_of_closures%s@ \
        @[<hov 1>%a@]\
        )@]"
      (Flambda_colours.prim_constructive ())
      (Flambda_colours.normal ())
      (Function_declarations.print) function_decls
  else
    Format.fprintf ppf "@[<hov 1>(%sset_of_closures%s@ \
        @[<hov 1>%a@]@ \
        @[<hov 1>(env@ %a)@]\
        )@]"
      (Flambda_colours.prim_constructive ())
      (Flambda_colours.normal ())
      (Function_declarations.print) function_decls
      (Var_within_closure.Map.print Simple.print) closure_elements

let free_names { phantom; function_decls; closure_elements } =
  if phantom then Name_occurrences.empty
  else
    Var_within_closure.Map.fold
      (fun closure_var bound_to free_names ->
         Name_occurrences.add_closure_var
           (Name_occurrences.union (Simple.free_names bound_to) free_names)
           closure_var Name_mode.normal)
      closure_elements
      (Function_declarations.free_names function_decls)

let apply_renaming ({ phantom; function_decls; closure_elements } as t) renaming =
  let function_decls' =
    Function_declarations.apply_renaming function_decls renaming
  in
  let closure_elements' =
    Var_within_closure.Map.filter_map
      (fun var simple ->
        if Renaming.closure_var_is_used renaming var
        then Some (Simple.apply_renaming simple renaming)
        else None)
      closure_elements
  in
  if function_decls == function_decls' && closure_elements == closure_elements'
  then t
  else
    { phantom; function_decls = function_decls'; closure_elements = closure_elements' }

let all_ids_for_export { phantom; function_decls; closure_elements } =
  if phantom then Ids_for_export.empty
  else
    let function_decls_ids =
      Function_declarations.all_ids_for_export function_decls
    in
    Var_within_closure.Map.fold
      (fun _closure_var simple ids -> Ids_for_export.add_simple ids simple)
      closure_elements function_decls_ids

let filter_function_declarations t ~f =
  let function_decls = Function_declarations.filter t.function_decls ~f in
  { t with function_decls }
